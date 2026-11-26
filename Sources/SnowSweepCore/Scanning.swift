import Foundation
import Darwin

/// 扫描引擎契约。Mole 不可用、版本不匹配或命令失败时，上层无需改动即可降级。
public protocol Scanning: Sendable {
    var sourceLabel: String { get }
    var isAvailable: Bool { get }
    func version() throws -> String
    func statusJSON() throws -> Data
    func analyzeJSON(path: String?) throws -> Data
    func cleanPreviewJSON() throws -> Data
}

/// 扫描源工厂。单元测试注入 MockProvider 即可覆盖降级链路，不需要真实 mo。
public protocol ScanningProvider: Sendable {
    func makeScanner() -> any Scanning
}

public struct DefaultScanningProvider: ScanningProvider {
    public init() {}
    public func makeScanner() -> any Scanning { MoleBridge() }
}

private struct FixedScanningProvider: ScanningProvider {
    let scanner: any Scanning
    func makeScanner() -> any Scanning { scanner }
}

/// 统一的扫描输出契约。Mole 与内置扫描器都产出这个结构，UI 只依赖它。
public struct ScanPayload: Codable, Sendable {
    public let source: String
    public let items: [ScanItem]
    public let gaps: [ScanGap]
    public let truncated: Bool

    public init(source: String, items: [ScanItem], gaps: [ScanGap] = [], truncated: Bool = false) {
        self.source = source
        self.items = items
        self.gaps = gaps
        self.truncated = truncated
    }
}

/// 临时错误重试策略。只针对 EINTR 这类可以安全重试的中断，权限错误不重试。
public struct ScanRetryPolicy: Sendable {
    public let maxAttempts: Int
    public init(maxAttempts: Int = 3) { self.maxAttempts = max(1, maxAttempts) }
}

/// 判断错误是否为可安全重试的 POSIX 中断（可能被 NSError 包了一层）。
public func isInterruptedIOError(_ error: Error) -> Bool {
    if errno == EINTR { return true }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain && ns.code == EINTR { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == NSPOSIXErrorDomain, underlying.code == EINTR { return true }
    return false
}

/// 对 EINTR 做有限重试；其余错误立即抛出，不做无意义重试。
public func retryOnInterruption<T>(attempts: Int = 3, operation: () throws -> T) throws -> T {
    let limit = max(1, attempts)
    var attempt = 0
    while true {
        do {
            return try operation()
        } catch {
            attempt += 1
            guard isInterruptedIOError(error), attempt < limit else { throw error }
        }
    }
}

/// 流式进度。onProgress 返回 false 表示用户取消。
public struct ScanProgress: Sendable {
    public let scanned: Int
    public let kept: Int
    public let currentPath: String

    public init(scanned: Int, kept: Int, currentPath: String) {
        self.scanned = scanned
        self.kept = kept
        self.currentPath = currentPath
    }
}

public struct ScanStreamSummary: Sendable, Codable {
    public let scanned: Int
    public let kept: Int
    public let skipped: Int
    public let gaps: [ScanGap]
    public let truncated: Bool
    public let cancelled: Bool

    public init(
        scanned: Int, kept: Int, skipped: Int = 0,
        gaps: [ScanGap] = [], truncated: Bool = false, cancelled: Bool = false
    ) {
        self.scanned = scanned
        self.kept = kept
        self.skipped = skipped
        self.gaps = gaps
        self.truncated = truncated
        self.cancelled = cancelled
    }
}

/// 流式接收端。实现者可只留计数，避免大扫描把 payload 全放进内存。
public protocol ScanEventSink: Sendable {
    func accept(_ item: ScanItem)
    func accept(_ gap: ScanGap)
    func finish(truncated: Bool)
}

/// 默认接收端：最多保留 maxItems 条，超出后只计数并标记截断。
/// 这是"大扫描 payload 内存截断保护"的落点。
public final class ScanPayloadCollector: ScanEventSink, @unchecked Sendable {
    private let lock = NSLock()
    public let maxItems: Int
    private var storedItems: [ScanItem] = []
    private var storedGaps: [ScanGap] = []
    private var overflow = 0
    private var wasTruncated = false

    public init(maxItems: Int = 5_000) {
        self.maxItems = max(1, maxItems)
    }

    public func accept(_ item: ScanItem) {
        lock.lock(); defer { lock.unlock() }
        if storedItems.count < maxItems {
            storedItems.append(item)
        } else {
            overflow += 1
            wasTruncated = true
        }
    }

    public func accept(_ gap: ScanGap) {
        lock.lock(); defer { lock.unlock() }
        storedGaps.append(gap)
    }

    public func finish(truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        wasTruncated = wasTruncated || truncated
    }

    public var itemCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedItems.count
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return overflow
    }

    public var payload: ScanPayload {
        lock.lock(); defer { lock.unlock() }
        return ScanPayload(
            source: "collector",
            items: storedItems,
            gaps: storedGaps,
            truncated: wasTruncated
        )
    }
}

/// 内置扫描器：不依赖 Homebrew / mo，用 FileManager 遍历。
/// 定位是「保证功能不缺失」的降级路径，规则判定仍由 RuleEngine 独立完成。
public struct NativeScanner: Scanning, Sendable {
    public let maxItems: Int
    public let maxPayloadItems: Int
    public let retryPolicy: ScanRetryPolicy

    public init(
        maxItems: Int = 10_000,
        maxPayloadItems: Int = 5_000,
        retryPolicy: ScanRetryPolicy = ScanRetryPolicy()
    ) {
        self.maxItems = maxItems
        self.maxPayloadItems = maxPayloadItems
        self.retryPolicy = retryPolicy
    }

    public var sourceLabel: String { "内置扫描（Mole 不可用）" }
    public var isAvailable: Bool { true }

    public func version() throws -> String { "native-0.1.0" }

    public func statusJSON() throws -> Data {
        let home = NSHomeDirectory()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
        return try JSONEncoder().encode(StatusPayload(source: "native", freeBytes: free, totalBytes: total))
    }

    /// 流式扫描。符号链接不跟随；iCloud 未下载占位文件直接跳过，避免触发云端下载。
    @discardableResult
    public func streamAnalyze(
        path: String? = nil,
        onProgress: (@Sendable (ScanProgress) -> Bool)? = nil,
        sink: any ScanEventSink
    ) throws -> ScanStreamSummary {
        let root = path.map { NSString(string: $0).expandingTildeInPath } ?? NSHomeDirectory()
        let fileManager = FileManager.default
        var scanned = 0
        var kept = 0
        var skipped = 0
        var gaps: [ScanGap] = []
        var truncated = false
        var cancelled = false
        var deduplicator = HardLinkDeduplicator()

        let enumerator: FileManager.DirectoryEnumerator?
        do {
            enumerator = try retryOnInterruption(attempts: retryPolicy.maxAttempts) {
                fileManager.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [
                        .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            }
        } catch {
            let kind: ScanGap.Kind = isInterruptedIOError(error) ? .transientIO : .opendirFailed
            let gap = ScanGap(kind: kind, path: root, detail: "重试 \(retryPolicy.maxAttempts) 次后仍失败：\(error)")
            sink.accept(gap)
            gaps.append(gap)
            sink.finish(truncated: false)
            return ScanStreamSummary(scanned: 0, kept: 0, gaps: gaps)
        }
        guard let enumerator else {
            let gap = ScanGap(kind: .opendirFailed, path: root)
            sink.accept(gap)
            gaps.append(gap)
            sink.finish(truncated: false)
            return ScanStreamSummary(scanned: 0, kept: 0, gaps: gaps)
        }

        for case let url as URL in enumerator {
            if let progress = onProgress {
                if !progress(ScanProgress(scanned: scanned, kept: kept, currentPath: url.path)) {
                    cancelled = true
                    break
                }
            }
            scanned += 1

            let values: URLResourceValues?
            do {
                values = try retryOnInterruption(attempts: retryPolicy.maxAttempts) {
                    try url.resourceValues(forKeys: [
                        .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                        .fileSizeKey, .contentModificationDateKey
                    ])
                }
            } catch {
                // 读取属性失败不能再按 0 字节计入，否则会低估空间且给出错误判定。
                let kind: ScanGap.Kind = isInterruptedIOError(error) ? .transientIO : .other
                let gap = ScanGap(kind: kind, path: url.path, detail: "读取属性失败：\(error)")
                sink.accept(gap)
                gaps.append(gap)
                skipped += 1
                continue
            }

            // 符号链接：不跟随遍历，也不计入体积，直接跳过整棵子树。
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                skipped += 1
                continue
            }
            // iCloud 占位：只看到占位文件时不能读内容，否则会触发下载。
            if Self.isCloudPlaceholder(url, values: values) {
                skipped += 1
                continue
            }
            // 内存保护：达到上限后不再接收条目，但继续计数以便 UI 显示"还能扫多少"。
            guard kept < maxItems else {
                truncated = true
                skipped += 1
                continue
            }
            guard deduplicator.register(path: url.path) else {
                skipped += 1
                continue
            }

            let item = ScanItem(
                path: url.path,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                identity: FileIdentity.capture(at: url.path)
            )
            sink.accept(item)
            kept += 1
        }

        if truncated {
            let gap = ScanGap(
                kind: .truncated,
                path: root,
                detail: "达到上限 \(maxItems) 条，已跳过 \(skipped) 条",
                severity: .critical,
                scope: .wholeScan
            )
            sink.accept(gap)
            gaps.append(gap)
        }
        sink.finish(truncated: truncated)
        return ScanStreamSummary(
            scanned: scanned, kept: kept, skipped: skipped,
            gaps: gaps, truncated: truncated, cancelled: cancelled
        )
    }

    public func analyzeJSON(path: String? = nil) throws -> Data {
        let collector = ScanPayloadCollector(maxItems: min(maxItems, maxPayloadItems))
        _ = try streamAnalyze(path: path, sink: collector)
        var payload = collector.payload
        payload = ScanPayload(
            source: "native",
            items: payload.items,
            gaps: payload.gaps,
            truncated: payload.truncated
        )
        return try JSONEncoder().encode(payload)
    }

    /// 降级模式预览：只展示极小一组高置信 safe 缓存，且必须是磁盘上真实存在的路径。
    /// 这不是"凭空生成清理预览"——每条都来自实际枚举，完整清理仍需 Mole CLI。
    public struct NativeSafeRoot: Sendable {
        public let name: String
        public let pattern: String
        public let reason: String

        public init(name: String, pattern: String, reason: String) {
            self.name = name
            self.pattern = pattern
            self.reason = reason
        }
    }

    public static let highConfidenceSafeRoots: [NativeSafeRoot] = [
        NativeSafeRoot(
            name: "Chrome 浏览器缓存", pattern: "~/Library/Caches/com.google.Chrome",
            reason: "浏览网页时的临时文件，不包含书签、历史记录和密码"
        ),
        NativeSafeRoot(
            name: "Safari 浏览器缓存", pattern: "~/Library/Caches/com.apple.Safari",
            reason: "浏览网页时的临时文件，不包含书签、历史记录和密码"
        ),
        NativeSafeRoot(
            name: "崩溃报告", pattern: "~/Library/Logs/DiagnosticReports",
            reason: "历史崩溃日志，如无排障需求可清理"
        ),
        NativeSafeRoot(
            name: "npm 下载缓存", pattern: "~/.npm/_cacache",
            reason: "安装包时留下的临时副本，删除后下次安装会重新下载"
        )
    ]

    public func cleanPreviewJSON() throws -> Data {
        var items: [ScanItem] = []
        var gaps: [ScanGap] = [
            ScanGap(
                kind: .other,
                path: "降级模式",
                detail: "仅展示 \(Self.highConfidenceSafeRoots.count) 类高置信缓存预览；完整清理需安装 Mole CLI",
                severity: .info,
                scope: .wholeScan
            )
        ]
        for root in Self.highConfidenceSafeRoots {
            let expanded = NSString(string: root.pattern).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let collector = ScanPayloadCollector(maxItems: 200)
            let summary = try streamAnalyze(path: expanded, sink: collector)
            items.append(contentsOf: collector.payload.items.filter { $0.path != expanded })
            gaps.append(contentsOf: summary.gaps)
        }
        return try JSONEncoder().encode(ScanPayload(
            source: "native-safe-preview",
            items: items,
            gaps: gaps,
            truncated: items.count >= 200 * Self.highConfidenceSafeRoots.count
        ))
    }

    /// iCloud 占位文件识别：.icloud 后缀或"是 ubiquitous 但未下载"。
    public static func isCloudPlaceholder(_ url: URL, values: URLResourceValues?) -> Bool {
        if url.lastPathComponent.hasSuffix(".icloud") { return true }
        guard let values else { return false }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .downloaded { return true }
        return false
    }
}


// MARK: - 规则根驱动扫描（V0.3.1 热修）

/// 带超时的目录列举。macOS 上某些云盘/文件提供者目录会在 `open` 里无限等待，
/// 直接 `FileManager.contentsOfDirectory` 会把整次扫描卡死。这里用独立进程
/// 列名字，超时就 SIGKILL，主扫描继续走，并把目录记为缺口。
public enum BoundedDirectoryLister {
    /// 列目录的结果必须区分“超时”和“没有权限”。把两者都折成 nil 会把
    /// 104 个 TCC 拒绝的目录误报成“超过 2 秒无响应”，用户也就无法判断
    /// 到底该去授权还是该检查云盘。
    public enum Result: Sendable, Equatable {
        case names([String])
        case timedOut
        case permissionDenied
        case failed
    }

    /// 4 秒足够慢磁盘与首次冷读；真正阻塞的云盘/文件提供者仍会被终止。
    public static let defaultTimeout: TimeInterval = 4

    private final class ListingState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }

    public static func list(
        atPath path: String,
        timeout: TimeInterval = defaultTimeout
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-1", "-a", "--", path]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failed }

        let state = ListingState()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            state.markTimedOut()
            if process.isRunning { process.terminate() }
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        timer.resume()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        timer.cancel()
        process.waitUntilExit()
        if state.didTimeOut { return .timedOut }

        let errorText = (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .lowercased()
        guard process.terminationStatus == 0 else {
            if errorText.contains("operation not permitted") || errorText.contains("permission denied") {
                return .permissionDenied
            }
            return .failed
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let names = text.split(separator: "\n").map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return .names(names)
    }

    /// 需要目录名的调用方保持旧接口；根扫描用 `list` 读取具体失败原因。
    public static func names(atPath path: String, timeout: TimeInterval = defaultTimeout) -> [String]? {
        guard case let .names(names) = list(atPath: path, timeout: timeout) else { return nil }
        return names
    }
}

/// 由规则库还原出的扫描根。只枚举规则真正关心的目录，不再先走完整个家目录。
/// 根会做嵌套收敛：父根已经覆盖时，子根自动去掉。
public struct RuleRootPlan: Sendable, Equatable {
    public let roots: [String]
    public init(roots: [String]) { self.roots = roots }
}

public enum RuleRootPlanner {
    /// 把规则 pattern 还原为“第一个 `**` 之前”的根；中间有 `*`/`?` 时按真实目录展开。
    public static func plan(
        rules: [Rule],
        home: String = NSHomeDirectory(),
        scope: ScanScope = .userOnly
    ) -> RuleRootPlan {
        let expandedHome = NSString(string: home).standardizingPath
        var found: [String] = []
        for rule in rules {
            for path in candidateRoots(for: rule.pathPattern, home: expandedHome) {
                let normalized = NSString(string: path).standardizingPath
                guard isInScope(normalized, home: expandedHome, scope: scope) else { continue }
                guard FileManager.default.fileExists(atPath: normalized) else { continue }
                found.append(normalized)
            }
        }

        // 父根覆盖子根：~/Library/Caches 已包含 ~/Library/Caches/Yarn，后者无需重复扫。
        let sorted = Set(found).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
        var roots: [String] = []
        for path in sorted {
            let covered = roots.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            if !covered { roots.append(path) }
        }
        return RuleRootPlan(roots: roots)
    }

    static func isInScope(_ path: String, home: String, scope: ScanScope) -> Bool {
        switch scope {
        case .wholeDisk: return true
        case .userOnly: return path == home || path.hasPrefix(home + "/")
        }
    }

    /// 只截到第一个 `**` 之前；`~/Downloads/*.dmg` 这类没有 `**` 的规则会保留文件通配。
    static func candidateRoots(for pattern: String, home: String) -> [String] {
        let expanded = expandHomePrefix(pattern, home: home)
        let prefix: String
        if let range = expanded.range(of: "**") {
            prefix = String(expanded[..<range.lowerBound])
        } else {
            prefix = expanded
        }
        var trimmed = prefix
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return [] }
        return expandGlob(trimmed, home: home)
    }

    static func expandHomePrefix(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + String(pattern.dropFirst()) }
        return pattern
    }

    /// 手写一级一级展开，避免依赖 libc glob 的平台差异，也保证隐藏目录可显式命中。
    static func expandGlob(_ pattern: String, home: String) -> [String] {
        let absolute = NSString(string: pattern).standardizingPath
        let components = absolute.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        var bases = ["/"]
        for component in components {
            if component.contains("*") || component.contains("?") {
                var next: [String] = []
                for base in bases {
                    guard let names = BoundedDirectoryLister.names(atPath: base) else { continue }
                    for name in names where globMatch(name, pattern: component) {
                        next.append(join(base, name))
                    }
                }
                bases = next
            } else {
                bases = bases.map { join($0, component) }
            }
            if bases.isEmpty { return [] }
        }
        return bases.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/" + component : base + "/" + component
    }

    static func globMatch(_ name: String, pattern: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return name.range(of: regex, options: .regularExpression) != nil
    }
}

/// 多个规则根并发时共享的计数与缺口。所有写入走同一把锁，汇总只做一次。
private final class RootScanAggregate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxItemsPerRoot: Int
    private var scanned = 0
    private var kept = 0
    private var skipped = 0
    private var truncated = false
    private var cancelled = false
    private var gaps: [ScanGap] = []

    init(maxItemsPerRoot: Int) {
        self.maxItemsPerRoot = maxItemsPerRoot
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func beginCandidate(path: String) -> (allowed: Bool, progress: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return (false, ScanProgress(scanned: scanned, kept: kept, currentPath: path)) }
        scanned += 1
        return (true, ScanProgress(scanned: scanned, kept: kept, currentPath: path))
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func addKept() {
        lock.lock(); kept += 1; lock.unlock()
    }

    func addSkipped(_ count: Int = 1) {
        lock.lock(); skipped += count; lock.unlock()
    }

    func addGap(_ gap: ScanGap) {
        lock.lock(); gaps.append(gap); lock.unlock()
    }

    func markTruncated(root: String, sink: any ScanEventSink) {
        lock.lock()
        truncated = true
        let gap = ScanGap(
            kind: .truncated,
            path: root,
            detail: "该规则根达到候选上限 \(maxItemsPerRoot) 条，只保留前 \(maxItemsPerRoot) 条",
            severity: .warning,
            scope: .directory
        )
        gaps.append(gap)
        lock.unlock()
        sink.accept(gap)
    }

    func markTruncatedForTimeout() {
        lock.lock(); truncated = true; lock.unlock()
    }

    func summary() -> ScanStreamSummary {
        lock.lock(); defer { lock.unlock() }
        return ScanStreamSummary(
            scanned: scanned, kept: kept, skipped: skipped,
            gaps: gaps, truncated: truncated, cancelled: cancelled
        )
    }
}

/// 规则根扫描器：每个扫描根的“一级子项”是一个清理候选，目录体积递归累加。
/// 这样候选数从家目录的几万条降到数百条，规则根之外的文件不再吃掉条目预算。
public struct RuleRootScanner: Sendable {
    public let scanner: NativeScanner
    public let engine: RuleEngine
    public let home: String
    public let maxItemsPerRoot: Int
    public let maxConcurrentRoots: Int
    /// 整次扫描的硬上限；nil 表示沿用旧行为。到点返回已读部分并写全局缺口。
    public let overallTimeout: TimeInterval?
    /// 进程外扫描时由 XPC 服务注入；返回 true 后当前候选和目录体积统计都会尽快停下。
    public let cancellationCheck: (@Sendable () -> Bool)?

    public init(
        scanner: NativeScanner = NativeScanner(),
        engine: RuleEngine,
        home: String = NSHomeDirectory(),
        maxItemsPerRoot: Int = 2_000,
        maxConcurrentRoots: Int = 1,
        overallTimeout: TimeInterval? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.scanner = scanner
        self.engine = engine
        self.home = NSString(string: home).standardizingPath
        self.maxItemsPerRoot = max(1, maxItemsPerRoot)
        self.maxConcurrentRoots = max(1, maxConcurrentRoots)
        self.overallTimeout = overallTimeout
        self.cancellationCheck = cancellationCheck
    }

    public var sourceLabel: String { "规则根扫描（内置）" }

    @discardableResult
    public func streamAnalyze(
        scope: ScanScope = .userOnly,
        onProgress: (@Sendable (ScanProgress) -> Bool)? = nil,
        sink: any ScanEventSink
    ) throws -> ScanStreamSummary {
        let plan = RuleRootPlanner.plan(rules: engine.ruleBook.rules, home: home, scope: scope)
        let aggregate = RootScanAggregate(maxItemsPerRoot: maxItemsPerRoot)
        let concurrency = max(1, min(maxConcurrentRoots, max(1, plan.roots.count)))

        let semaphore = DispatchSemaphore(value: concurrency)
        let queue = DispatchQueue(label: "snowsweep.rule-roots", attributes: .concurrent)
        let group = DispatchGroup()
        for root in plan.roots {
            if aggregate.isCancelled || cancellationCheck?() == true { break }
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                scanRoot(root, aggregate: aggregate, onProgress: onProgress, sink: sink)
            }
        }
        let timedOut: Bool
        if let overallTimeout {
            timedOut = group.wait(timeout: .now() + overallTimeout) == .timedOut
        } else {
            group.wait()
            timedOut = false
        }

        if timedOut {
            aggregate.cancel()
            let seconds = Int((overallTimeout ?? 0).rounded())
            let gap = ScanGap(
                kind: .other,
                path: "扫描总时限",
                detail: "扫描超过 \(seconds) 秒仍未返回，已停下未读完的目录；清单只代表读到的部分。",
                severity: .critical,
                scope: .wholeScan
            )
            aggregate.addGap(gap)
            aggregate.markTruncatedForTimeout()
            sink.accept(gap)
        }

        let summary = aggregate.summary()
        sink.finish(truncated: summary.truncated)
        return summary
    }

    private func scanRoot(
        _ root: String,
        aggregate: RootScanAggregate,
        onProgress: (@Sendable (ScanProgress) -> Bool)?,
        sink: any ScanEventSink
    ) {
        let rootURL = URL(fileURLWithPath: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { return }
        guard !aggregate.isCancelled, cancellationCheck?() != true else { return }

        let candidates: [URL]
        if isDirectory.boolValue {
            switch BoundedDirectoryLister.list(atPath: root) {
            case let .names(names):
                candidates = names.map { rootURL.appendingPathComponent($0) }
            case .timedOut:
                let gap = ScanGap(
                    kind: .opendirFailed,
                    path: root,
                    detail: "列举目录超过 \(Int(BoundedDirectoryLister.defaultTimeout)) 秒，已跳过；可能是云盘、网络盘或文件提供者无响应。",
                    severity: .warning,
                    scope: .directory
                )
                sink.accept(gap)
                aggregate.addGap(gap)
                aggregate.addSkipped()
                return
            case .permissionDenied:
                let gap = ScanGap(
                    kind: .permissionDenied,
                    path: root,
                    detail: "系统未授予该目录读取权限，已跳过；授权说明见「权限清单」。",
                    severity: .warning,
                    scope: .directory
                )
                sink.accept(gap)
                aggregate.addGap(gap)
                aggregate.addSkipped()
                return
            case .failed:
                let gap = ScanGap(
                    kind: .opendirFailed,
                    path: root,
                    detail: "目录打不开，可能已损坏或被其他程序占用。",
                    severity: .warning,
                    scope: .directory
                )
                sink.accept(gap)
                aggregate.addGap(gap)
                aggregate.addSkipped()
                return
            }
        } else {
            candidates = [rootURL]
        }

        var keptInRoot = 0
        for candidate in candidates {
            if aggregate.isCancelled || cancellationCheck?() == true { return }
            let token = aggregate.beginCandidate(path: candidate.path)
            guard token.allowed else { return }
            if let onProgress, !onProgress(token.progress) {
                aggregate.cancel()
                return
            }
            // 每 200 项让出一点磁盘 I/O，避免扫描把前台页面切换拖成假死。
            if token.progress.scanned % 200 == 0 {
                Thread.sleep(forTimeInterval: 0.003)
            }

            let values: URLResourceValues?
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .contentModificationDateKey
                ])
            } catch {
                let gap = makeGap(error, path: candidate.path)
                sink.accept(gap)
                aggregate.addGap(gap)
                aggregate.addSkipped()
                continue
            }

            if values?.isSymbolicLink == true {
                aggregate.addSkipped()
                continue
            }
            if NativeScanner.isCloudPlaceholder(candidate, values: values) {
                aggregate.addSkipped()
                continue
            }

            let isDir = values?.isDirectory == true
            let size: Int64
            if isDir {
                let result = directorySize(candidate)
                if aggregate.isCancelled || cancellationCheck?() == true { return }
                if let error = result.error {
                    let gap = makeGap(error, path: candidate.path)
                    sink.accept(gap)
                    aggregate.addGap(gap)
                    aggregate.addSkipped()
                    continue
                }
                size = result.bytes
            } else {
                size = Int64(values?.fileSize ?? 0)
            }

            let item = ScanItem(
                path: Self.canonicalPath(candidate.path),
                sizeBytes: size,
                modifiedAt: values?.contentModificationDate,
                identity: FileIdentity.capture(at: candidate.path)
            )
            let verdict = isDir
                ? engine.verdictForDirectory(item)
                : engine.verdict(for: item)
            // 规则根之外不再收集 unknown：清理页只展示规则真正覆盖的候选。
            guard verdict.risk != .unknown else {
                aggregate.addSkipped()
                continue
            }
            sink.accept(item)
            aggregate.addKept()
            keptInRoot += 1

            if keptInRoot >= maxItemsPerRoot {
                aggregate.markTruncated(root: root, sink: sink)
                return
            }
        }
    }

    /// `/var` 与 `/private/var` 这类 firmlink 会让候选路径与规则前缀不同；
    /// 候选本身存在，先 realpath 再交给 RuleEngine，避免真实命中被判 unknown。
    private static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func directorySize(_ directory: URL) -> (bytes: Int64, error: Error?) {
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey, .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return (0, nil)
        }
        var total: Int64 = 0
        var entries = 0
        for case let child as URL in enumerator {
            entries += 1
            if entries % 256 == 0 && (Task.isCancelled || cancellationCheck?() == true) {
                return (total, nil)
            }
            do {
                let values = try child.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true { continue }
                if NativeScanner.isCloudPlaceholder(child, values: values) { continue }
                total += Int64(values.fileSize ?? 0)
            } catch {
                return (total, error)
            }
        }
        return (total, nil)
    }

    private func makeGap(_ error: Error, path: String) -> ScanGap {
        let ns = error as NSError
        let kind: ScanGap.Kind
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            kind = .permissionDenied
        } else if ns.domain == NSCocoaErrorDomain && ns.code == 257 {
            kind = .permissionDenied
        } else if isInterruptedIOError(error) {
            kind = .transientIO
        } else {
            kind = .opendirFailed
        }
        // 界面与导出报告只给可行动的中文说明；底层 NSError 原文留在系统日志里，
        // 不把整段 UserInfo 倒进用户面前。
        let friendlyDetail: String
        switch kind {
        case .permissionDenied:
            friendlyDetail = "系统未授予该目录读取权限，已跳过；授权说明见「权限清单」。"
        case .transientIO:
            friendlyDetail = "读取时连续遇到临时错误，重试后仍失败，已跳过。"
        default:
            friendlyDetail = "目录打不开，可能已损坏或被其他程序占用。"
        }
        return ScanGap(kind: kind, path: path, detail: friendlyDetail)
    }
}

struct StatusPayload: Codable, Sendable {
    let source: String
    let freeBytes: Int64
    let totalBytes: Int64
}

/// APFS 硬链接/克隆去重：以 (device, inode) 为键，避免同一份数据被重复计入体积。
/// 取不到 inode 时保守计入，宁可高估也不静默丢失文件。
public struct HardLinkDeduplicator {
    private var seen: Set<String> = []

    public init() {}

    @discardableResult
    public mutating func register(path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes?[.deviceIdentifier] as? NSNumber)?.uint64Value ?? 0
        guard inode != 0 else { return true }
        return seen.insert("\(device):\(inode)").inserted
    }

    public var uniqueCount: Int { seen.count }
}

/// 简易占用探测：只用 libproc，不依赖 AppKit。
/// 精确匹配（进程可执行文件在目标目录内）→ protected；
/// 粗判（目标位于已运行 App 的应用数据目录）→ 只把 safe 降 review，不武断保护。
public protocol OccupancyProbing: Sendable {
    func probe(path: String) -> Occupancy
}

public struct NativeOccupancyProbe: OccupancyProbing {
    public init() {}

    public func probe(path: String) -> Occupancy {
        let normalized = NSString(string: path).expandingTildeInPath
        let executables = Self.runningExecutablePaths()
        for executable in executables {
            if executable.hasPrefix(normalized + "/") { return .exact }
            if let appRoot = Self.appBundleRoot(of: executable),
               normalized == appRoot || normalized.hasPrefix(appRoot + "/") {
                return .exact
            }
        }
        // 粗判：~/Library/Application Support/<AppName> 且同名 App 正在运行。
        let supportPrefix = NSHomeDirectory() + "/Library/Application Support/"
        if normalized.hasPrefix(supportPrefix) {
            let appName = String(normalized.dropFirst(supportPrefix.count).split(separator: "/").first ?? "")
            if !appName.isEmpty,
               executables.contains(where: { $0.localizedCaseInsensitiveContains("/\(appName).app/") }) {
                return .approximate
            }
        }
        return .none
    }

    private static func runningExecutablePaths() -> [String] {
        var pids = [Int32](repeating: 0, count: 4096)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        var result: [String] = []
        for pid in pids.prefix(Int(count) / MemoryLayout<Int32>.size) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = buffer.withUnsafeMutableBufferPointer { raw in
                proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
            }
            guard length > 0 else { continue }
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            result.append(String(decoding: bytes, as: UTF8.self))
        }
        return result
    }

    private static func appBundleRoot(of executable: String) -> String? {
        var current = executable as NSString
        while current.length > 0 {
            if current.pathExtension == "app" { return current as String }
            let parent = current.deletingLastPathComponent
            if parent == current as String || parent == "/" { return nil }
            current = parent as NSString
        }
        return nil
    }
}

/// 扫描器选择：优先 Mole，缺失/版本不符/探测失败时降级到内置扫描。
public enum ScannerResolver: Sendable {
    public static func resolve(provider: any ScanningProvider = DefaultScanningProvider()) -> any Scanning {
        let candidate = provider.makeScanner()
        guard candidate.isAvailable else { return NativeScanner() }
        do {
            let found = try candidate.version()
            // 只有"同主版本且不低于最低版本"才认为 JSON 契约兼容。
            return ScannerVersion.compatibility(found: found, required: MoleBridge.minimumSupportedVersion) == .compatible
                ? candidate
                : NativeScanner()
        } catch {
            return NativeScanner()
        }
    }

    /// 旧接口兼容：直接注入一个扫描器实例。
    public static func resolve(preferred: (any Scanning)?) -> any Scanning {
        guard let preferred else { return resolve() }
        return resolve(provider: FixedScanningProvider(scanner: preferred))
    }
}

/// 标准 SemVer 解析：major.minor.patch[-prerelease][+build]，允许前缀文字（如 "mole 1.2.0"）。
public struct SemanticVersion: Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(parsing text: String) {
        let pattern = #"(?:^|[^\d])(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if let preRange = Range(match.range(at: 4), in: text) {
            self.prerelease = String(text[preRange])
        } else {
            self.prerelease = nil
        }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 有 prerelease 的版本低于正式版。
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(a), .some(b)): return a < b
        case (nil, nil): return false
        }
    }
}

public enum VersionCompatibility: String, Sendable {
    case compatible            // 同主版本且 >= 最低版本，契约可信
    case olderIncompatible     // 同主版本但过低
    case breakingMajor         // 主版本低于约定，明显不兼容
    case futureMajor           // 主版本更高，契约未知，保守降级
    case unparseable
}

public enum ScannerVersion: Sendable {
    public static func compatibility(found: String, required: String) -> VersionCompatibility {
        guard let foundVersion = SemanticVersion(parsing: found),
              let requiredVersion = SemanticVersion(parsing: required) else { return .unparseable }
        if foundVersion.major < requiredVersion.major { return .breakingMajor }
        if foundVersion.major > requiredVersion.major { return .futureMajor }
        return foundVersion >= requiredVersion ? .compatible : .olderIncompatible
    }

    /// 旧接口：只判断是否可用于当前契约。
    public static func isVersion(_ found: String, atLeast minimum: String) -> Bool {
        compatibility(found: found, required: minimum) == .compatible
    }
}

/// Mole JSON 输出解析器。契约测试用 fixture JSON 验证，不依赖真实 mo 可执行文件。
public enum MolePayloadParser: Sendable {
    public static func parseScanItems(_ data: Data) throws -> [ScanItem] {
        let json = try JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let direct = json as? [Any] {
            array = direct
        } else if let object = json as? [String: Any],
                  let nested = (object["items"] ?? object["data"]) as? [Any] {
            array = nested
        } else {
            throw ParseError.unexpectedShape
        }

        return array.compactMap { raw in
            guard let object = raw as? [String: Any] else { return nil }
            guard let path = (object["path"] ?? object["pathPattern"]) as? String else { return nil }
            let size = (object["sizeBytes"] as? NSNumber)?
                .int64Value ?? (object["size"] as? NSNumber)?.int64Value ?? 0
            let owner = object["owner"] as? String
            let modifiedAt: Date? = (object["modifiedAt"] as? NSNumber).map {
                Date(timeIntervalSinceReferenceDate: $0.doubleValue)
            }
            return ScanItem(
                path: path, sizeBytes: size, modifiedAt: modifiedAt, owner: owner,
                identity: FileIdentity.capture(at: path)
            )
        }
    }

    public enum ParseError: Error, LocalizedError {
        case unexpectedShape
        public var errorDescription: String? {
            "扫描结果既不是数组，也没有 items/data 字段"
        }
    }
}
