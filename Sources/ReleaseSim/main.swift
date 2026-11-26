import Foundation
#if canImport(Darwin)
import Darwin
#endif
import SnowSweepCore

// ============================================================
// SnowSweep 发布前仿真验收（多人物 × 多轮 × 多维度）
//
// 自用软件没有真实账号体系，"多人"落地为仿真多人物画像：
//   每个画像有不同的文件布局、自定义保护路径、勾选行为；
//   每个画像跑多轮（首次清理 → 重扫幂等 → 变更拒绝）；
//   全程从多维度断言（判定/闸门/复核/审计/幂等/性能/边界/中文）。
//
// 用的是生产同款真实组件：真实 RuleEngine + NativeScanner(lstat) +
// SystemFileTrasher(真废纸篓) + SystemTargetVerifier + AuditLog(SHA256)。
// 样本全部带 token，结束按 token 精确自清理，不碰用户任何现有文件。
//
// 这是 V1.0.0 自用正式版的发布准入门槛，退出码 0 = 全绿。
// ============================================================

// MARK: - 维度统计

final class SimChecker: @unchecked Sendable {
    struct Tally { var passed = 0; var failed = 0 }
    private var tallies: [String: Tally] = [:]
    private(set) var totalPassed = 0
    private(set) var totalFailed = 0

    func check(_ dimension: String, _ name: String, _ ok: Bool, _ detail: String = "") {
        var tally = tallies[dimension] ?? Tally()
        if ok { tally.passed += 1; totalPassed += 1 } else { tally.failed += 1; totalFailed += 1 }
        tallies[dimension] = tally
        let mark = ok ? "[通过]" : "[失败]"
        print("  \(mark) [\(dimension)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func summary() -> [(String, Tally)] {
        tallies.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

let checker = SimChecker()

func section(_ title: String) { print("\n=== \(title) ===") }

// MARK: - 人物画像

enum SelectionMode: String {
    case allSafeOnly    = "只勾选安全项"
    case partialSafe    = "只勾选部分安全项"
    case submitAllPaths = "把所有路径都勾上（含危险项）"
}

struct SampleSpec {
    let relPath: String
    let sizeBytes: Int
    let directory: Bool
    let protected: Bool     // 落在自定义保护清单内
}

struct Persona {
    let id: String
    let name: String
    let note: String
    let mode: SelectionMode
    let specs: [SampleSpec]
}

let token = "SnowSweepSim-\(UUID().uuidString)"
let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let simRoot = cachesRoot.appendingPathComponent(token, isDirectory: true)

func personaRoot(_ persona: Persona) -> URL {
    simRoot.appendingPathComponent(persona.id, isDirectory: true)
}

func samplePath(_ persona: Persona, _ spec: SampleSpec) -> URL {
    personaRoot(persona).appendingPathComponent(spec.relPath)
}

func protectedPaths(for persona: Persona) -> [String] {
    persona.specs.filter { $0.protected }.map { samplePath(persona, $0).path }
}

let personas: [Persona] = [
    Persona(
        id: "developer", name: "开发者·小林", note: "缓存多、习惯全选安全项",
        mode: .allSafeOnly,
        specs: [
            SampleSpec(relPath: "\(token)-npm-cache.dat", sizeBytes: 4096, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-pycache.dat", sizeBytes: 2048, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-build-dir", sizeBytes: 0, directory: true, protected: false),
            SampleSpec(relPath: "\(token)-build-dir/artifact.dat", sizeBytes: 8192, directory: false, protected: false)
        ]
    ),
    Persona(
        id: "office", name: "办公·王女士", note: "浏览器缓存/日志，只勾一部分",
        mode: .partialSafe,
        specs: [
            SampleSpec(relPath: "\(token)-browser-cache.dat", sizeBytes: 3000, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-crash-log.dat", sizeBytes: 1500, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-keep.log", sizeBytes: 700, directory: false, protected: false)
        ]
    ),
    Persona(
        id: "cautious", name: "谨慎·老周", note: "自定义保护清单，护住特定目录",
        mode: .allSafeOnly,
        specs: [
            SampleSpec(relPath: "\(token)-ordinary.dat", sizeBytes: 2500, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-vault", sizeBytes: 0, directory: true, protected: true),
            SampleSpec(relPath: "\(token)-vault/secret.dat", sizeBytes: 9999, directory: false, protected: true)
        ]
    ),
    Persona(
        id: "messy", name: "随手·阿明", note: "不看清单全勾，含被保护项",
        mode: .submitAllPaths,
        specs: [
            SampleSpec(relPath: "\(token)-tmp-a.dat", sizeBytes: 1800, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-tmp-b.dat", sizeBytes: 2200, directory: false, protected: false),
            SampleSpec(relPath: "\(token)-project", sizeBytes: 0, directory: true, protected: true),
            SampleSpec(relPath: "\(token)-project/keep.dat", sizeBytes: 4321, directory: false, protected: true)
        ]
    )
]

// MARK: - 清理痕迹

func trashDirectory() -> URL {
    FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
}

func cleanupAll() {
    let fm = FileManager.default
    try? fm.removeItem(at: simRoot)
    // 审计日志写在临时目录，按 token 精确匹配
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.contains(token) {
            try? fm.removeItem(at: entry)
        }
    }
    // 废纸篓里的样本名带 token（macOS 会加时间戳后缀，用子串匹配）
    let trash = trashDirectory()
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
    let src = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
    return FileManager.default.fileExists(atPath: src.path) ? src : nil
}

func auditURL(for persona: Persona) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(token)-\(persona.id)-audit.jsonl")
}

// MARK: - 场景构建

func buildLayout(_ persona: Persona) throws {
    let root = personaRoot(persona)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for spec in persona.specs {
        let url = samplePath(persona, spec)
        if spec.directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x5A, count: max(1, spec.sizeBytes)).write(to: url)
        }
    }
}

func scan(_ persona: Persona, engine: RuleEngine) throws -> (payload: ScanPayload, summary: ScanStreamSummary) {
    let collector = ScanPayloadCollector(maxItems: 2_000)
    let summary = try NativeScanner().streamAnalyze(path: personaRoot(persona).path, sink: collector)
    return (collector.payload, summary)
}

// 合成"规则库未覆盖/需确认"的判定条目，代表仿真中 review/unknown 这两类现实存在。
func syntheticNonSafeVerdicts() -> [Verdict] {
    let item = ScanItem(path: "/tmp/\(token)-outside-rule.dat", sizeBytes: 100)
    return [
        Verdict(item: item, risk: .review, explanation: "需人工确认的仿真条目", needConfirm: true),
        Verdict(item: ScanItem(path: "/tmp/\(token)-unknown.dat", sizeBytes: 100),
                risk: .unknown, explanation: "规则库未覆盖", needConfirm: true)
    ]
}

func hasChinese(_ text: String) -> Bool {
    let pattern = #"[\u{4e00}-\u{9fff}]"#
    return text.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - 主流程

func run() throws {
    guard let ruleFile = rulesURL() else {
        FileHandle.standardError.write("找不到 Rules/rules.json，请从项目根目录运行\n".data(using: .utf8)!)
        exit(2)
    }

    section("0. 仿真环境准备")
    checker.check("环境", "四个人物画像已定义", personas.count == 4, "\(personas.count) 个画像")
    checker.check("环境", "样本根隔离在 Caches 且带唯一 token",
                  simRoot.path.contains("Caches") && simRoot.lastPathComponent.hasPrefix("SnowSweepSim-"))
    try FileManager.default.createDirectory(at: simRoot, withIntermediateDirectories: true)

    for persona in personas {
        section("人物：\(persona.name)（\(persona.note)）")

        // 每人物独立规则引擎，注入该人物的自定义保护路径（真实加载 + 校验）
        let engine = try RuleBookMigrator.loadEngine(
            builtinURL: ruleFile, overlayURL: nil,
            extraProtectedPaths: protectedPaths(for: persona)
        )
        try buildLayout(persona)
        let built = persona.specs.allSatisfy { fmFileExists(samplePath(persona, $0)) }
        checker.check("判定", "文件布局搭建完成", built, "\(persona.specs.count) 个样本")

        // ---------- 轮次 1：扫描 → 判定 → 闸门 → dry-run → 确认清理 ----------
        section("  轮次 1／3：首次扫描与清理")
        let (payload, summary) = try scan(persona, engine: engine)
        checker.check("判定", "真实扫描覆盖全部样本",
                      persona.specs.allSatisfy { scanned(payload, contains: samplePath(persona, $0).path) },
                      "扫描 \(summary.kept) 条")
        checker.check("判定", "扫描无缺口、无截断", payload.gaps.isEmpty && !payload.truncated)

        var verdicts = payload.items.map { engine.verdict(for: $0) }
        verdicts.append(contentsOf: syntheticNonSafeVerdicts())
        let report = ScanReport(
            scanStatus: "complete", totalBytes: verdicts.reduce(Int64(0)) { $0 + $1.item.sizeBytes },
            verdicts: verdicts, scanGaps: []
        )
        checker.check("判定", "报告可清理", report.canClean)

        // 判定正确性：真实样本里受保护的判 protected，其余判 safe
        for spec in persona.specs {
            let path = samplePath(persona, spec).path
            guard let verdict = verdicts.first(where: { $0.item.path == path }) else { continue }
            let expectedOK = spec.protected ? verdict.risk == .protected : verdict.risk == .safe
            checker.check("判定", "样本判定符合规则：\(spec.relPath)", expectedOK,
                          "实际 \(verdict.risk.rawValue)")
        }
        // 中文标识：判定解释是中文人话
        checker.check("中文标识", "所有判定解释均为中文",
                      verdicts.allSatisfy { hasChinese($0.explanation) })

        // 闸门：按人物勾选策略提交路径，验证只放行 defaultSelected
        let submitted: Set<String> = {
            switch persona.mode {
            case .allSafeOnly: return Set(verdicts.filter { $0.defaultSelected }.map { $0.item.path })
            case .partialSafe: return Set(verdicts.filter { $0.defaultSelected }.prefix(1).map { $0.item.path })
            case .submitAllPaths: return Set(verdicts.map { $0.item.path })  // 含 protected/review/unknown
            }
        }()
        let entries = CleanupSelection.safeEntries(from: report, selectedPaths: submitted)
        checker.check("闸门", "只放行 safe 且非需确认项",
                      entries.allSatisfy { $0.verdict.defaultSelected },
                      "提交 \(submitted.count) 条 → 放行 \(entries.count) 条")
        if persona.mode == .submitAllPaths {
            let denied = submitted.count - entries.count
            checker.check("闸门", "误传的危险项被静默拦截", denied > 0, "拦截 \(denied) 条")
        }

        // dry-run 不删文件
        let audit = AuditLog(fileURL: auditURL(for: persona))
        let coordinator = DeletionCoordinator(
            trasher: SystemFileTrasher(), audit: audit, policy: DeletionPolicy(),
            verifier: SystemTargetVerifier(),
            protectionCheck: { path in engine.isProtected(path) }, requireIdentity: true
        )
        _ = try coordinator.dryRun(items: payload.items, report: report, engine: engine)
        checker.check("审计", "dry-run 已留痕且样本未删除",
                      fmFileExists(samplePath(persona, persona.specs[0]))
                      && (try? audit.events().contains { $0.action == .dryRun }) == true)

        // 确认清理：真移废纸篓
        var moved = 0
        for entry in entries {
            if let _ = try coordinator.moveToTrash(
                entry.verdict.item, ruleID: entry.ruleID, report: report, resolution: .stop
            ) { moved += 1 }
        }
        checker.check("判定", "确认清理全部放行项成功", moved == entries.count, "\(moved)/\(entries.count)")

        // 审计链
        let verification = try audit.verify()
        checker.check("审计", "SHA256 哈希链完整无断链", verification.isValid,
                      "\(verification.lineCount) 条记录")
        checker.check("审计", "全程无永久删除记录",
                      !(try audit.events().contains { $0.action == .permanentDelete }))

        // ---------- 轮次 2：重扫，验证幂等 ----------
        section("  轮次 2／3：重扫验证幂等")
        let (rescan, _) = try scan(persona, engine: engine)
        let rescanPaths = Set(rescan.items.map { $0.path })
        let cleanedPaths = Set(entries.map { $0.verdict.item.path })
        checker.check("幂等", "已清理项在重扫中不再出现",
                      cleanedPaths.isDisjoint(with: rescanPaths), "核对 \(cleanedPaths.count) 条")
        // 受保护项仍在（保护清单没有被绕过）
        let protectedStillThere = persona.specs.filter { $0.protected && !$0.directory }
            .allSatisfy { fmFileExists(samplePath(persona, $0)) }
        if persona.specs.contains(where: { $0.protected }) {
            checker.check("幂等", "受保护项重扫后仍在原处", protectedStillThere)
        }

        // ---------- 轮次 3：注入变更，验证删除前复核拒绝 ----------
        section("  轮次 3／3：变更体删除被拒")
        do {
            let victim = personaRoot(persona).appendingPathComponent("\(token)-victim.dat")
            let target = personaRoot(persona).appendingPathComponent("\(token)-swap.dat")
            try Data("victim".utf8).write(to: victim)
            try Data("original".utf8).write(to: target)
            let originalIdentity = FileIdentity.capture(at: target.path)!
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
            let item = ScanItem(path: target.path, sizeBytes: 8, identity: originalIdentity)
            var rejected = false
            do { _ = try coordinator.moveToTrash(item, ruleID: nil, report: report, resolution: .stop) }
            catch is TargetRevalidationError { rejected = true }
            checker.check("复核", "符号链接替换被拒", rejected)
            checker.check("复核", "被指向的重要文件未被删", fmFileExists(victim))
        }
        do {
            let target = personaRoot(persona).appendingPathComponent("\(token)-replaced.dat")
            try Data("old".utf8).write(to: target)
            let originalIdentity = FileIdentity.capture(at: target.path)!
            try FileManager.default.removeItem(at: target)
            try Data("new-content".utf8).write(to: target)
            let item = ScanItem(path: target.path, sizeBytes: 11, identity: originalIdentity)
            var rejected = false
            do { _ = try coordinator.moveToTrash(item, ruleID: nil, report: report, resolution: .stop) }
            catch is TargetRevalidationError { rejected = true }
            checker.check("复核", "inode 变更被拒", rejected)
        }
    }

    // ---------- 全局维度：性能 / 边界 ----------
    section("全局维度：性能与边界")
    guard let ruleFile = rulesURL() else { exit(2) }
    let engine = try RuleBookMigrator.loadEngine(builtinURL: ruleFile, overlayURL: nil)
    let perfItems = (0..<5_000).map { i in
        ScanItem(path: "\(cachesRoot.path)/\(token)-perf-\(i)/cache.dat", sizeBytes: Int64(i))
    }
    let start = Date()
    let perfVerdicts = perfItems.map { engine.verdict(for: $0) }
    let elapsed = Date().timeIntervalSince(start)
    checker.check("性能", "5000 条真实判定快速完成",
                  perfVerdicts.count == 5_000 && elapsed < 2.0,
                  String(format: "%.3f 秒", elapsed))

    let edgePaths = [
        "\(cachesRoot.path)/\(token)-特殊字符（测试）.dat",
        "\(cachesRoot.path)/\(token)-空格 与符号#@.dat",
        "\(cachesRoot.path)/\(token)-\(String(repeating: "长", count: 180)).dat"
    ]
    let edgeVerdicts = edgePaths.map { engine.verdict(for: ScanItem(path: $0, sizeBytes: 0)) }
    checker.check("边界", "特殊字符/零字节/超长路径判定不崩溃",
                  edgeVerdicts.count == 3 && edgeVerdicts.allSatisfy { !$0.explanation.isEmpty })
    checker.check("边界", "边界条目 explanation 非空且中文",
                  edgeVerdicts.allSatisfy { hasChinese($0.explanation) })

    // ---------- 全局维度：V0.3.0 体验补全（真实组件，不用 Mock） ----------
    section("全局维度：恢复 / 规模 / 脱敏 / 范围")

    // 恢复清单：审计链有效才列出；只认成功的移废纸篓/备份，不碰永久删除。
    let rollbackLog = AuditLog(fileURL: simRoot.appendingPathComponent("rollback-audit.jsonl"))
    try rollbackLog.append(action: .moveToTrash, path: "\(cachesRoot.path)/\(token)-rollback.dat",
                           ruleID: "test-rule", sizeBytes: 123, success: true)
    try rollbackLog.append(action: .permanentDelete, path: "\(cachesRoot.path)/\(token)-gone.dat",
                           success: true)
    let rollbackCandidates = try AuditRollback(audit: rollbackLog).candidates()
    checker.check("恢复", "恢复清单只列可恢复项、排除永久删除",
                  rollbackCandidates.count == 1 &&
                  rollbackCandidates[0].displayName == "\(token)-rollback.dat" &&
                  rollbackCandidates[0].destination == .trash)
    checker.check("恢复", "恢复只给原路径与位置，不自动移回文件",
                  fmFileExists(URL(fileURLWithPath: rollbackCandidates[0].originalPath)) == false)

    // 规模闸门：超过 200 项或 5GB 必须显式确认，未确认不得进入删除层。
    let itemGate = BatchSizeGate.check(count: 201, bytes: 1)
    let byteGate = BatchSizeGate.check(count: 1, bytes: 5 * 1024 * 1024 * 1024 + 1)
    let normalGate = BatchSizeGate.check(count: 200, bytes: 5 * 1024 * 1024 * 1024)
    checker.check("规模", "超 200 项强制二次确认且未确认不放行",
                  itemGate.requiresConfirmation && !itemGate.allows(acknowledged: false)
                  && itemGate.allows(acknowledged: true))
    checker.check("规模", "超 5GB 强制二次确认",
                  byteGate.requiresConfirmation && !byteGate.allows(acknowledged: false))
    checker.check("规模", "常规批次无需额外确认", normalGate == .allowed)

    // 导出脱敏：隐藏用户名但不改判定、证据语义与中文标识。
    let redactor = ReportRedactor(username: "example")
    let demoPath = "/Users/example/Library/Caches/\(token).dat"
    let redactedReport = ScanReport(
        scanStatus: "complete", totalBytes: 1,
        verdicts: [Verdict(item: ScanItem(path: demoPath, sizeBytes: 1),
                           risk: .safe, explanation: "规则原文",
                           evidence: ["rule:test", "path:\(demoPath)"])]
    )
    let redactedData = try ReportExporter.json(report: redactedReport, redactor: redactor)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let redactedPayload = try decoder.decode(ReportExporter.ExportedReport.self, from: redactedData)
    let redactedItem = redactedPayload.items[0]
    checker.check("脱敏", "导出路径中的用户名被收敛为 ~",
                  redactedItem.path == "~/Library/Caches/\(token).dat"
                  && !redactedData.contains(Data("/Users/example".utf8)))
    checker.check("脱敏", "脱敏保留判定、规则原文与证据链",
                  redactedItem.risk == "safe" && redactedItem.explanation == "规则原文"
                  && redactedItem.evidence == ["rule:test", "path:~/Library/Caches/\(token).dat"])
    checker.check("脱敏", "原扫描报告未被脱敏反向修改",
                  redactedReport.verdicts[0].item.path == demoPath)

    // 授权范围：默认收敛到用户目录；数据库可读不等于本软件拿到 FDA。
    checker.check("范围", "默认仅扫描用户目录",
                  ScanScope.default == .userOnly
                  && ScanScope.userOnly.rootPath() == NSString(string: NSHomeDirectory()).standardizingPath)
    let readableSnapshot = PermissionSnapshot(grants: [], gaps: [], sourceLabel: "仿真")
    checker.check("范围", "数据库可读不冒称本软件已获全盘授权",
                  FDAScopeInspector.status(from: readableSnapshot) == .databaseReadableWithoutAppGrant)
    checker.check("范围", "扩大扫描范围不放宽删除判定",
                  ScanScope.wholeDisk.explain.contains("受保护"))
}

func fmFileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func scanned(_ payload: ScanPayload, contains path: String) -> Bool {
    payload.items.contains { $0.path == path }
}

do {
    try run()
} catch {
    checker.check("环境", "仿真过程无异常", false, "\(error)")
}

// exit() 会跳过 defer，清理必须显式调用，确保测试痕迹不残留。
cleanupAll()

print("\n========================================")
print("各维度结果：")
for (dimension, tally) in checker.summary() {
    let padded = dimension.padding(toLength: 8, withPad: " ", startingAt: 0)
    print("  \(padded) 通过 \(tally.passed) / 失败 \(tally.failed)")
}
print("发布前仿真验收：通过 \(checker.totalPassed) / 失败 \(checker.totalFailed)")
print("========================================")
exit(checker.totalFailed == 0 ? 0 : 1)
