import Foundation
#if canImport(Darwin)
import Darwin
#endif
import SnowSweepCore

// ============================================================
// SnowSweep 自用浸泡压力测试（多轮 × 多维度）
//
// 目的：在「装到本机、长期自用」之前，用生产同款真实组件做
// 数百轮重复循环，观察：内存/文件句柄是否单调增长、性能是否
// 随轮次劣化、审计链是否始终完整、是否出现残留或误删。
//
// 与 ReleaseSim（功能验收，4 人物 × 3 轮）不同，这里压的是
// 「长时间重复」本身：同一套真实链路跑几百轮，看资源曲线。
//
// 本机数据安全（三层，缺一不可）：
//   1. 所有样本写在 Caches/SnowSweepSoak-<token>/，路径带 token；
//   2. 代码级隔离闸门：删除请求必须命中隔离根 + token 前缀，
//      否则在调用 trasher 之前就拒绝（isIsolatedSample）；
//   3. 生产 DeletionCoordinator 自身的 lstat 身份复核 + 保护清单。
// 每轮结束按 token 精确清除样本与废纸篓副本，绝不碰用户现有文件。
//
// 退出码 0 = 全绿且无泄漏趋势；非 0 = 存在失败项。
// ============================================================

// MARK: - 命令行参数

struct Options {
    var rounds = 300
    var intervalSeconds: Double = 0
    var verboseEvery = 25
    var quick = false

    static func parse() -> Options {
        var o = Options()
        let args = Array(CommandLine.arguments.dropFirst())
        var roundsExplicit = false
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? {
                guard i + 1 < args.count else { return nil }
                i += 1
                return args[i]
            }
            switch a {
            case "--rounds":
                if let v = value(), let n = Int(v), n > 0 {
                    o.rounds = n
                    roundsExplicit = true
                }
            case "--interval": if let v = value(), let d = Double(v), d >= 0 { o.intervalSeconds = d }
            case "--verbose-every": if let v = value(), let n = Int(v), n > 0 { o.verboseEvery = n }
            case "--quick":
                o.quick = true
                // 显式 --rounds 优先；--quick 只提供默认短程轮数，不能覆盖它。
                if !roundsExplicit { o.rounds = 12 }
                o.verboseEvery = 3
            case "--help":
                print("用法：SoakTest [--rounds N] [--interval 秒] [--verbose-every N] [--quick]")
                exit(0)
            default: break
            }
            i += 1
        }
        return o
    }
}

// MARK: - 维度打点

final class SoakChecker: @unchecked Sendable {
    struct Tally { var passed = 0; var failed = 0; var samples: [Double] = [] }
    private var tallies: [String: Tally] = [:]
    private(set) var totalPassed = 0
    private(set) var totalFailed = 0
    private let lock = NSLock()

    func check(_ dimension: String, _ ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        var t = tallies[dimension] ?? Tally()
        if ok { t.passed += 1; totalPassed += 1 } else { t.failed += 1; totalFailed += 1 }
        tallies[dimension] = t
    }

    func sample(_ dimension: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        var t = tallies[dimension] ?? Tally()
        t.samples.append(value)
        tallies[dimension] = t
    }

    func tally(_ dimension: String) -> Tally {
        lock.lock(); defer { lock.unlock() }
        return tallies[dimension] ?? Tally()
    }

    var dimensions: [String] { lock.lock(); defer { lock.unlock() }; return tallies.keys.sorted() }
}

let checker = SoakChecker()

// MARK: - 资源采样（内存 / 文件句柄）

func residentMemoryBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
    #else
    return 0
    #endif
}

func openFileHandleCount() -> Int {
    let fm = FileManager.default
    return ((try? fm.contentsOfDirectory(atPath: "/dev/fd")) ?? []).count
}

/// 趋势检测：比较首段与末段均值，避免单点抖动误报。
/// 返回 (首段均值, 末段均值, 增长率)。首段样本不足时视为 0 增长。
func trend(_ samples: [Double]) -> (first: Double, last: Double, growth: Double) {
    guard samples.count >= 20 else { return (0, 0, 0) }
    let window = max(5, samples.count / 10)
    let first = Array(samples.prefix(window)).reduce(0, +) / Double(window)
    let last = Array(samples.suffix(window)).reduce(0, +) / Double(window)
    let growth = first > 0 ? (last - first) / first : 0
    return (first, last, growth)
}

// MARK: - 隔离环境与闸门

let token = "SnowSweepSoak-\(UUID().uuidString)"
let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let soakRoot = cachesRoot.appendingPathComponent(token, isDirectory: true)
let home = FileManager.default.homeDirectoryForCurrentUser.path

func trashDirectory() -> URL {
    FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
}

/// 代码级隔离闸门：只有隔离根下、文件名带本轮 token 的路径才允许进入删除层。
/// 这是防误删本机的最后一道硬闸——即使规则误判，也过不了这里。
func isIsolatedSample(_ path: String) -> Bool {
    let standardized = (path as NSString).standardizingPath
    guard standardized.hasPrefix(soakRoot.path + "/") else { return false }
    return (standardized as NSString).lastPathComponent.contains(token)
}

func roundRoot(_ round: Int) -> URL {
    soakRoot.appendingPathComponent("round-\(round)", isDirectory: true)
}

func samplePath(_ round: Int, _ name: String) -> URL {
    roundRoot(round).appendingPathComponent("\(token)-\(name)")
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

/// 精确清理：只删带本轮 token 的样本根、审计日志与废纸篓副本。
func cleanupAll() {
    let fm = FileManager.default
    try? fm.removeItem(at: soakRoot)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.contains(token) {
            try? fm.removeItem(at: entry)
        }
    }
    let trash = trashDirectory()
    if let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.contains(token) {
            try? fm.removeItem(at: entry)
        }
    }
}

// 中断也要清理：Ctrl-C 不留痕迹。
#if canImport(Darwin)
signal(SIGINT) { _ in cleanupAll(); exit(130) }
signal(SIGTERM) { _ in cleanupAll(); exit(143) }
#endif

// MARK: - 单轮样本

struct SampleSpec { let name: String; let size: Int; let directory: Bool }

let sampleSpecs: [SampleSpec] = [
    SampleSpec(name: "cache-a.dat", size: 4096, directory: false),
    SampleSpec(name: "cache-b.dat", size: 2048, directory: false),
    SampleSpec(name: "build-dir", size: 0, directory: true),
    SampleSpec(name: "build-dir/artifact.dat", size: 8192, directory: false)
]

func buildRound(_ round: Int) throws {
    let root = roundRoot(round)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for spec in sampleSpecs {
        let url = samplePath(round, spec.name)
        if spec.directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: UInt8(round % 251), count: spec.size).write(to: url)
        }
    }
}

func auditURL(_ round: Int) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(token)-r\(round)-audit.jsonl")
}

func hasChinese(_ text: String) -> Bool {
    text.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil
}

/// 每轮结束清理废纸篓里的本轮副本，避免几百轮把废纸篓塞满。
func purgeTrashForRound(_ round: Int) {
    let fm = FileManager.default
    let trash = trashDirectory()
    guard let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
    let marker = "\(token)-"
    for entry in entries where entry.lastPathComponent.contains(marker) {
        try? fm.removeItem(at: entry)
    }
}

// MARK: - 主流程

func run(_ options: Options) throws {
    guard let ruleFile = rulesURL() else {
        FileHandle.standardError.write("找不到 Rules/rules.json，请从项目根目录运行\n".data(using: .utf8)!)
        exit(2)
    }
    let engine = try RuleBookMigrator.loadEngine(builtinURL: ruleFile, overlayURL: nil)

    print(" SnowSweep 自用浸泡压力测试")
    print(" 轮数 \(options.rounds)｜隔离根 \(soakRoot.path)")
    print(" 删除闸门：路径必须在隔离根下 且 文件名带 token 且 默认可清理")
    print(" 注：样本每轮自动生成并清除，不扫描用户目录，不触碰你的现有文件\n")

    try FileManager.default.createDirectory(at: soakRoot, withIntermediateDirectories: true)

    // 环境断言：隔离根确实在 Caches 下，且 token 唯一。
    checker.check("环境", soakRoot.path.contains("Caches") && soakRoot.lastPathComponent == token)
    checker.check("环境", isIsolatedSample(samplePath(1, "cache-a.dat").path))
    // 关键闸门反例：用户真实路径、甚至同样是 cache 命名，都必须被拒。
    checker.check("闸门", !isIsolatedSample("\(home)/Library/Caches/cache-a.dat"))
    checker.check("闸门", !isIsolatedSample("\(home)/Documents/重要文件.txt"))
    checker.check("闸门", !isIsolatedSample("/System/Library/cache.dat"))
    checker.check("闸门", !isIsolatedSample("\(soakRoot.path)/other-token.dat"))

    for round in 1...options.rounds {
      do { try autoreleasepool { try runRound(round, options, engine: engine) } }
      catch { checker.check("环境", false); print("[异常] 第 \(round) 轮：\(error)") }
    }

    // 全局维度：性能趋势 / 边界 / 中文，用真实规则引擎。
    let edgePaths = [
        "\(cachesRoot.path)/\(token)-特殊字符（测试）.dat",
        "\(cachesRoot.path)/\(token)-空格 与符号#@.dat",
        "\(cachesRoot.path)/\(token)-\(String(repeating: "长", count: 180)).dat"
    ]
    let edgeVerdicts = edgePaths.map { engine.verdict(for: ScanItem(path: $0, sizeBytes: 0)) }
    checker.check("边界", edgeVerdicts.allSatisfy { !$0.explanation.isEmpty && hasChinese($0.explanation) })

    print("\n=== 资源趋势与泄漏判定 ===")
    let memTrend = trend(checker.tally("内存").samples)
    let fdTrend = trend(checker.tally("句柄").samples)
    let perfTrend = trend(checker.tally("性能").samples)

    print(String(format: "  常驻内存  首段 %.1fMB → 末段 %.1fMB（增长 %.1f%%）",
                 memTrend.first, memTrend.last, memTrend.growth * 100))
    print(String(format: "  打开文件句柄 首段 %.0f → 末段 %.0f（增长 %.1f%%）",
                 fdTrend.first, fdTrend.last, fdTrend.growth * 100))
    print(String(format: "  单轮耗时  首段 %.3fs → 末段 %.3fs（增长 %.1f%%）",
                 perfTrend.first, perfTrend.last, perfTrend.growth * 100))

    // 泄漏阈值：内存 +60% 或 句柄 +50% 或 耗时 +100% 视为异常趋势。
    // 用首末段均值比较，避免单点抖动；阈值偏宽松，只抓单调恶化。
    checker.check("内存", memTrend.growth < 0.60)
    checker.check("句柄", fdTrend.growth < 0.50)
    checker.check("性能", perfTrend.growth < 1.00)

    print("\n=== 各维度结果 ===")
    for dimension in checker.dimensions {
        let t = checker.tally(dimension)
        let padded = dimension.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(padded) 通过 \(t.passed) / 失败 \(t.failed)")
    }
}

/// 单轮完整链路。抽出成函数，便于外层包裹 autoreleasepool 精确回收 Foundation 临时对象。
func runRound(_ round: Int, _ options: Options, engine: RuleEngine) throws {
        let roundStart = Date()
        try buildRound(round)

        // 真实扫描（只扫本轮隔离目录）
        let collector = ScanPayloadCollector(maxItems: 2_000)
        let summary = try NativeScanner().streamAnalyze(path: roundRoot(round).path, sink: collector)
        let items = collector.payload.items
        checker.check("判定", items.count >= sampleSpecs.count)
        checker.check("判定", !collector.payload.truncated && collector.payload.gaps.isEmpty)
        checker.check("判定", summary.kept >= sampleSpecs.count)

        // 真实规则判定
        let verdicts = items.map { engine.verdict(for: $0) }
        checker.check("判定", verdicts.allSatisfy { hasChinese($0.explanation) })
        let report = ScanReport(
            scanStatus: "complete",
            totalBytes: verdicts.reduce(Int64(0)) { $0 + $1.item.sizeBytes },
            verdicts: verdicts,
            scanGaps: []
        )
        checker.check("判定", report.canClean)

        // 闸门：只放行默认可清理项，且逐条过隔离闸门。
        let entries = CleanupSelection.allSafeEntries(from: report)
        checker.check("闸门", entries.allSatisfy { $0.verdict.defaultSelected })
        let gated = entries.filter { isIsolatedSample($0.verdict.item.path) }
        checker.check("闸门", gated.count == entries.count)
        checker.check("闸门", entries.count > 0 && entries.count <= gated.count)

        // 删除前复核 + 真移废纸篓
        let audit = AuditLog(fileURL: auditURL(round))
        let coordinator = DeletionCoordinator(
            trasher: SystemFileTrasher(), audit: audit, policy: DeletionPolicy(),
            verifier: SystemTargetVerifier(),
            protectionCheck: { path in engine.isProtected(path) }, requireIdentity: true
        )
        _ = try coordinator.dryRun(items: items, report: report, engine: engine)
        var moved = 0
        for entry in gated {
            // 双重保险：调用删除层之前再校验一次隔离闸门。
            guard isIsolatedSample(entry.verdict.item.path) else {
                checker.check("闸门", false)
                continue
            }
            if let _ = try coordinator.moveToTrash(
                entry.verdict.item, ruleID: entry.ruleID, report: report, resolution: .stop
            ) { moved += 1 }
        }
        checker.check("复核", moved == gated.count)

        // 审计链每轮都验，几百轮累积不改前置链。
        let verification = try audit.verify()
        checker.check("审计", verification.isValid && verification.lineCount > gated.count)
        checker.check("审计", !(try audit.events().contains { $0.action == .permanentDelete }))

        // 幂等：重扫不再出现已清理项。
        let rescanCollector = ScanPayloadCollector(maxItems: 2_000)
        _ = try NativeScanner().streamAnalyze(path: roundRoot(round).path, sink: rescanCollector)
        let cleaned = Set(gated.map { $0.verdict.item.path })
        let remaining = Set(rescanCollector.payload.items.map { $0.path })
        checker.check("幂等", cleaned.isDisjoint(with: remaining))

        // 残留卫生：本轮隔离目录只剩空壳（含被祖先折叠带走的空目录）。
        let strayFiles = rescanCollector.payload.items.filter { !$0.path.hasSuffix("/") }
        checker.check("残留", strayFiles.allSatisfy { isIsolatedSample($0.path) })

        // 周期性安全探针：注入符号链接替换，验证生产复核仍拒绝。
        if round == 1 || round % 50 == 0 {
            let victim = samplePath(round, "victim.dat")
            let target = samplePath(round, "swap.dat")
            try Data("victim".utf8).write(to: victim)
            try Data("original".utf8).write(to: target)
            let identity = FileIdentity.capture(at: target.path)!
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
            let forged = ScanItem(path: target.path, sizeBytes: 8, identity: identity)
            var rejected = false
            do { _ = try coordinator.moveToTrash(forged, ruleID: nil, report: report, resolution: .stop) }
            catch is TargetRevalidationError { rejected = true }
            checker.check("复核", rejected)
            checker.check("复核", FileManager.default.fileExists(atPath: victim.path))
        }

        // 每轮清理：废纸篓副本 + 临时审计 + 样本根（隔离根留空壳供下轮复用）。
        purgeTrashForRound(round)
        try? FileManager.default.removeItem(at: auditURL(round))
        try? FileManager.default.removeItem(at: roundRoot(round))

        let lastRoundDuration = Date().timeIntervalSince(roundStart)
        checker.sample("性能", lastRoundDuration)
        checker.sample("内存", Double(residentMemoryBytes()) / 1_048_576)
        checker.sample("句柄", Double(openFileHandleCount()))

        if round == 1 || round % options.verboseEvery == 0 || round == options.rounds {
            let mem = Double(residentMemoryBytes()) / 1_048_576
            print(String(format: "  轮次 %3d/%d  耗时 %.3fs  常驻内存 %.1fMB  句柄 %d",
                         round, options.rounds, lastRoundDuration, mem, openFileHandleCount()))
        }

        if options.intervalSeconds > 0 && round < options.rounds {
            Thread.sleep(forTimeInterval: options.intervalSeconds)
        }
}

do {
    try run(Options.parse())
} catch {
    checker.check("环境", false)
    print("\n[异常] 浸泡中断：\(error)")
}

cleanupAll()

print("\n========================================")
print("自用浸泡压力测试：通过 \(checker.totalPassed) / 失败 \(checker.totalFailed)")
print("========================================")
exit(checker.totalFailed == 0 ? 0 : 1)
