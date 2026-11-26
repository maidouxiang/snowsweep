import Foundation

/// 用户规则目录的持久化契约。
///
/// 设计原则：
/// - 规则是数据，不是代码；
/// - 导入先存目录，默认不启用；
/// - 启用/停用只改状态文件，不改规则正文；
/// - 保护清单只增不减，内置 protect 规则不可被同 id 用户规则替换。
public struct UserRuleCatalog: Codable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: String?
    public var protectedPaths: [String]
    public var rules: [Rule]

    public init(
        schemaVersion: Int = 1,
        updatedAt: String? = nil,
        protectedPaths: [String] = [],
        rules: [Rule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.protectedPaths = protectedPaths
        self.rules = rules
    }
}

/// 启用状态与规则正文分开存：导入/删除规则不会顺手把状态写坏。
public struct UserRuleState: Codable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: String?
    public var enabledIDs: [String]
    /// 从规则草稿导入的 id。草稿必须先试扫，才允许启用。
    public var draftIDs: [String]?
    /// 已在本机成功试扫过的草稿 id；重新导入同 id 会清掉。
    public var trialedIDs: [String]?

    public init(
        schemaVersion: Int = 1,
        updatedAt: String? = nil,
        enabledIDs: [String] = [],
        draftIDs: [String]? = nil,
        trialedIDs: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.enabledIDs = enabledIDs
        self.draftIDs = draftIDs
        self.trialedIDs = trialedIDs
    }

    public func isDraft(_ id: String) -> Bool { (draftIDs ?? []).contains(id) }
    public func isTrialed(_ id: String) -> Bool { (trialedIDs ?? []).contains(id) }
}

public enum UserRuleImportOrigin: String, Sendable {
    case manual
    case draft
}

/// 草稿批次里被单独拦下的一条规则。安全子集导入时，不因一条重叠拖垮整批。
public struct RuleDraftRejection: Sendable, Hashable {
    public let id: String
    public let name: String
    public let pathPattern: String
    public let reasons: [String]

    public init(id: String, name: String, pathPattern: String, reasons: [String]) {
        self.id = id
        self.name = name
        self.pathPattern = pathPattern
        self.reasons = reasons
    }

    public var summary: String {
        let label = name.isEmpty ? id : "\(name)（\(id)）"
        return "\(label)：\(reasons.joined(separator: "；"))"
    }
}

public struct UserRuleImportSummary: Sendable {
    public let source: String
    public let importedIDs: [String]
    public let replacedIDs: [String]
    public let totalRules: Int
    public let enabledRules: Int
    public let rejectedRules: [RuleDraftRejection]

    public init(
        source: String,
        importedIDs: [String],
        replacedIDs: [String],
        totalRules: Int,
        enabledRules: Int,
        rejectedRules: [RuleDraftRejection] = []
    ) {
        self.source = source
        self.importedIDs = importedIDs
        self.replacedIDs = replacedIDs
        self.totalRules = totalRules
        self.enabledRules = enabledRules
        self.rejectedRules = rejectedRules
    }
}

public struct RuleTrialResult: Sendable {
    public let ruleID: String
    public let rootCount: Int
    public let itemCount: Int
    public let totalBytes: Int64
    public let gapsCount: Int
    public let truncated: Bool
    public let errorMessage: String?

    public init(
        ruleID: String,
        rootCount: Int,
        itemCount: Int,
        totalBytes: Int64,
        gapsCount: Int,
        truncated: Bool,
        errorMessage: String? = nil
    ) {
        self.ruleID = ruleID
        self.rootCount = rootCount
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.gapsCount = gapsCount
        self.truncated = truncated
        self.errorMessage = errorMessage
    }
}

public enum UserRuleRegistryError: Error, LocalizedError, Sendable {
    case unknownRule(String)
    case protectedRuleOverride(String)
    case trialRequired(String)
    case policy([ValidationIssue])
    case noSafeDraftRules([RuleDraftRejection])

    public var errorDescription: String? {
        switch self {
        case let .unknownRule(id):
            return "找不到用户规则：\(id)"
        case let .protectedRuleOverride(id):
            return "不能覆盖内置保护规则：\(id)"
        case let .trialRequired(id):
            return "规则草稿 \(id) 必须先试扫，才能启用"
        case let .policy(issues):
            let first = issues.first(where: { $0.severity == .error }) ?? issues.first
            return first.map { "用户规则未通过安全检查：\($0.message)" } ?? "用户规则未通过安全检查"
        case let .noSafeDraftRules(rejections):
            let details = rejections.prefix(3).map(\.summary).joined(separator: "；")
            return "这批草稿没有可安全导入的规则（\(rejections.count) 条全部被拦下）：\(details)"
        }
    }
}

/// 用户规则注册表：只做文件读写与合并，不执行规则正文。
public struct UserRuleRegistry: Sendable {
    public let directoryURL: URL

    public var catalogURL: URL { directoryURL.appendingPathComponent("rules.json") }
    public var stateURL: URL { directoryURL.appendingPathComponent("state.json") }
    public var receiptURL: URL { directoryURL.appendingPathComponent("import-receipt.json") }

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.directoryURL = support
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("Rules", isDirectory: true)
                .appendingPathComponent("User", isDirectory: true)
        }
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: catalogURL.path)
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    public func loadCatalog() throws -> UserRuleCatalog {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            return UserRuleCatalog()
        }
        let data = try Data(contentsOf: catalogURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UserRuleCatalog.self, from: data)
    }

    public func loadState() throws -> UserRuleState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return UserRuleState()
        }
        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UserRuleState.self, from: data)
    }

    /// 状态文件损坏时不阻断扫描：宁可全部保持停用，也不让坏状态把规则意外打开。
    public func loadStateLenient() -> UserRuleState {
        (try? loadState()) ?? UserRuleState()
    }

    public func enabledCount() -> Int {
        let catalog = (try? loadCatalog())?.rules ?? []
        let state = loadStateLenient()
        let ids = Set(catalog.map(\.id))
        return state.enabledIDs.filter { ids.contains($0) }.count
    }

    public func loadEnabledOverlay() throws -> UserRuleOverlay {
        let catalog = try loadCatalog()
        let state = loadStateLenient()
        let enabled = Set(state.enabledIDs)
        let rules = catalog.rules.filter { enabled.contains($0.id) }
        return UserRuleOverlay(
            schemaVersion: catalog.schemaVersion,
            protectedPaths: catalog.protectedPaths,
            rules: rules
        )
    }

    /// 扫描/手动保护统一从这里加载：内置规则 + 已启用用户规则。
    public func loadEngine(
        builtinURL: URL,
        extraProtectedPaths: [String] = []
    ) throws -> RuleEngine {
        let builtinData = try Data(contentsOf: builtinURL)
        try RuleBookValidator.assertValid(jsonData: builtinData)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let builtin = try decoder.decode(RuleBook.self, from: builtinData)
        let overlay = try loadEnabledOverlay()
        let policy = Self.policyIssues(rules: overlay.rules, builtin: builtin)
        if policy.contains(where: { $0.severity == .error }) {
            throw UserRuleRegistryError.policy(policy)
        }
        let merged = RuleBookMigrator.merge(builtIn: builtin, overlay: overlay)
        return try RuleEngine(ruleBook: merged, customProtectedPaths: extraProtectedPaths)
    }

    /// 导入用户规则。导入后强制停用，用户必须逐条试扫/启用。
    /// `builtinURL` 用于拦截“同名覆盖内置保护规则”。
    @discardableResult
    public func importRules(
        jsonData: Data,
        source: String,
        builtinURL: URL,
        confirmation: OverlayImportConfirmation = .userConfirmed,
        origin: UserRuleImportOrigin = .manual
    ) throws -> UserRuleImportSummary {
        let overlay = try RuleBookMigrator.importOverlay(jsonData: jsonData)
        let builtin = try Self.loadBuiltin(url: builtinURL)
        let policy = Self.policyIssues(rules: overlay.rules, builtin: builtin)
        if policy.contains(where: { $0.severity == .error }) {
            throw UserRuleRegistryError.policy(policy)
        }

        var catalog = try loadCatalog()
        var state = loadStateLenient()
        let importedIDs = Set(overlay.rules.map(\.id))
        let replaced = Set(catalog.rules.map(\.id)).intersection(importedIDs)

        catalog.rules.removeAll { importedIDs.contains($0.id) }
        catalog.rules.append(contentsOf: overlay.rules)
        for path in overlay.protectedPaths where !catalog.protectedPaths.contains(path) {
            catalog.protectedPaths.append(path)
        }
        catalog.updatedAt = Self.isoNow()
        state.enabledIDs.removeAll { importedIDs.contains($0) }
        state.trialedIDs = (state.trialedIDs ?? []).filter { !importedIDs.contains($0) }
        if origin == .draft {
            state.draftIDs = Array(Set(state.draftIDs ?? []).union(importedIDs)).sorted()
        } else {
            state.draftIDs = (state.draftIDs ?? []).filter { !importedIDs.contains($0) }
        }
        state.updatedAt = Self.isoNow()

        try ensureDirectory()
        try Self.write(catalog, to: catalogURL)
        try Self.write(state, to: stateURL)

        let fingerprint = OverlayFingerprint(
            sha256: try OverlayImportGuard.fingerprint(of: overlay),
            importedAt: Date(),
            source: source,
            ruleCount: overlay.rules.count,
            protectedPathCount: overlay.protectedPaths.count
        )
        try OverlayImportReceiptStore(fileURL: receiptURL).save(fingerprint)

        return UserRuleImportSummary(
            source: source,
            importedIDs: overlay.rules.map(\.id),
            replacedIDs: Array(replaced).sorted(),
            totalRules: catalog.rules.count,
            enabledRules: state.enabledIDs.count
        )
    }

    public func setEnabled(_ id: String, enabled: Bool) throws {
        let catalog = try loadCatalog()
        guard catalog.rules.contains(where: { $0.id == id }) else {
            throw UserRuleRegistryError.unknownRule(id)
        }
        var state = loadStateLenient()
        if enabled, state.isDraft(id), !state.isTrialed(id) {
            throw UserRuleRegistryError.trialRequired(id)
        }
        if enabled {
            if !state.enabledIDs.contains(id) { state.enabledIDs.append(id) }
        } else {
            state.enabledIDs.removeAll { $0 == id }
        }
        state.updatedAt = Self.isoNow()
        try ensureDirectory()
        try Self.write(state, to: stateURL)
    }

    /// 试扫成功后由 UI 调用；只记 id，不记扫描结果，重新导入同 id 会自动清掉。
    public func markTrialed(_ id: String) throws {
        let catalog = try loadCatalog()
        guard catalog.rules.contains(where: { $0.id == id }) else {
            throw UserRuleRegistryError.unknownRule(id)
        }
        var state = loadStateLenient()
        if !(state.trialedIDs ?? []).contains(id) {
            state.trialedIDs = Array(Set(state.trialedIDs ?? []).union([id])).sorted()
        }
        state.updatedAt = Self.isoNow()
        try ensureDirectory()
        try Self.write(state, to: stateURL)
    }

    /// 导入一份 `snow-rule-draft` 信封：先校验 kind / schema，再按单条规则分流。
    /// 与保护路径重叠或单条 schema 不合格的条目单独列出并拦下；安全条目照常导入，
    /// 不因为一条坏草稿把整批安全规则一起废掉。导入后仍全部停用，必须逐条试扫。
    @discardableResult
    public func importDrafts(
        jsonData: Data,
        source: String,
        builtinURL: URL
    ) throws -> UserRuleImportSummary {
        let normalized = try RuleDraftImporter.normalizedOverlayData(from: jsonData)
        let overlay = try RuleBookMigrator.importOverlay(jsonData: normalized)
        let builtin = try Self.loadBuiltin(url: builtinURL)

        var accepted: [Rule] = []
        var rejected: [RuleDraftRejection] = []
        var seenIDs = Set<String>()

        for rule in overlay.rules {
            var reasons: [String] = []
            if !seenIDs.insert(rule.id).inserted {
                reasons.append("同一份草稿里有重复规则 id")
            }
            let issues = Self.policyIssues(rules: [rule], builtin: builtin)
                .filter { $0.severity == .error }
            reasons.append(contentsOf: issues.map(\.message))
            if reasons.isEmpty {
                accepted.append(rule)
            } else {
                rejected.append(RuleDraftRejection(
                    id: rule.id,
                    name: rule.name,
                    pathPattern: rule.pathPattern,
                    reasons: reasons
                ))
            }
        }

        guard !accepted.isEmpty else {
            throw UserRuleRegistryError.noSafeDraftRules(rejected)
        }

        let safeOverlay = UserRuleOverlay(
            schemaVersion: 1,
            protectedPaths: overlay.protectedPaths,
            rules: accepted
        )
        let safeData = try RuleBookMigrator.exportOverlay(safeOverlay)
        let summary = try importRules(
            jsonData: safeData,
            source: source,
            builtinURL: builtinURL,
            origin: .draft
        )
        return UserRuleImportSummary(
            source: summary.source,
            importedIDs: summary.importedIDs,
            replacedIDs: summary.replacedIDs,
            totalRules: summary.totalRules,
            enabledRules: summary.enabledRules,
            rejectedRules: rejected
        )
    }

    public func remove(_ id: String) throws {
        var catalog = try loadCatalog()
        guard catalog.rules.contains(where: { $0.id == id }) else {
            throw UserRuleRegistryError.unknownRule(id)
        }
        catalog.rules.removeAll { $0.id == id }
        catalog.updatedAt = Self.isoNow()
        var state = loadStateLenient()
        state.enabledIDs.removeAll { $0 == id }
        state.draftIDs = (state.draftIDs ?? []).filter { $0 != id }
        state.trialedIDs = (state.trialedIDs ?? []).filter { $0 != id }
        state.updatedAt = Self.isoNow()
        try ensureDirectory()
        try Self.write(catalog, to: catalogURL)
        try Self.write(state, to: stateURL)
    }

    /// 导出用户规则；不包含启用状态，便于换机后重新逐条确认。
    public func exportCatalog() throws -> Data {
        let catalog = try loadCatalog()
        return try Self.encode(catalog)
    }

    // MARK: - 安全检查

    /// 用户规则只允许落在 `~/`；拒绝 `~/**` 这种一把抓全家的写法。
    /// 内置 protect / allowOverrideProtection 规则不可被同 id 用户规则替换；
    /// 非 protect 用户规则也不得与内置 protect 规则路径重叠，避免更具体的规则绕过保护。
    public static func policyIssues(rules: [Rule], builtin: RuleBook) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var builtinByID: [String: Rule] = [:]
        for rule in builtin.rules { builtinByID[rule.id] = rule }
        let protectRules = builtin.rules.filter { $0.actionType == .protect }

        for (index, rule) in rules.enumerated() {
            let base = "$.rules[\(index)]"
            if !rule.pathPattern.hasPrefix("~/") {
                issues.append(ValidationIssue(
                    path: base + ".pathPattern",
                    message: "用户规则只允许 ~/ 开头的家目录路径",
                    severity: .error
                ))
            }
            if rule.pathPattern == "~/**" || rule.pathPattern == "~" {
                issues.append(ValidationIssue(
                    path: base + ".pathPattern",
                    message: "不允许一把抓整个家目录；请写到具体应用或缓存目录",
                    severity: .error
                ))
            }
            if let original = builtinByID[rule.id],
               original.actionType == .protect || original.risk == .protected || original.allowOverrideProtection {
                issues.append(ValidationIssue(
                    path: base + ".id",
                    message: "不能覆盖内置保护规则：\(rule.id)",
                    severity: .error
                ))
            }
            if rule.actionType != .protect, rule.risk == .protected {
                issues.append(ValidationIssue(
                    path: base + ".risk",
                    message: "用户自定义 protected 规则必须使用 protect 动作",
                    severity: .error
                ))
            }
            if rule.actionType != .protect {
                let conflicts = protectRules.filter {
                    overlapsProtection(rule.pathPattern, $0.pathPattern)
                }
                if let conflict = conflicts.first {
                    issues.append(ValidationIssue(
                        path: base + ".pathPattern",
                        message: "规则路径与内置保护规则「\(conflict.name)」重叠，不能启用",
                        severity: .error
                    ))
                }
            }
        }
        return issues
    }

    /// 只比较通配符之前的字面前缀；两段路径互为祖先即视为重叠。
    /// 宁可要求用户把规则写得更具体，也不让新规则绕过内置保护。
    static func overlapsProtection(_ lhs: String, _ rhs: String) -> Bool {
        let a = literalPrefix(lhs)
        let b = literalPrefix(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
            || a.hasPrefix(b + "/")
            || b.hasPrefix(a + "/")
    }

    static func literalPrefix(_ pattern: String) -> String {
        let expanded = NSString(string: pattern).expandingTildeInPath
        var result = ""
        for character in expanded {
            if character == "*" || character == "?" { break }
            result.append(character)
        }
        var trimmed = String(result.drop(while: { $0 == "/" && result.count > 1 }))
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    public static func loadBuiltin(url: URL) throws -> RuleBook {
        let data = try Data(contentsOf: url)
        try RuleBookValidator.assertValid(jsonData: data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RuleBook.self, from: data)
    }

    // MARK: - 试扫

    /// 单条规则试扫：只读、限时、限条目。返回命中项数与体积，不执行删除。
    public static func trial(
        rule: Rule,
        builtin: RuleBook,
        home: String = NSHomeDirectory(),
        timeout: TimeInterval = 15
    ) -> RuleTrialResult {
        do {
            let engine = try RuleEngine(
                ruleBook: RuleBook(
                    version: "trial",
                    updatedAt: nil,
                    protectedPaths: builtin.protectedPaths,
                    rules: [rule]
                )
            )
            let collector = ScanPayloadCollector(maxItems: 200)
            let scanner = RuleRootScanner(
                engine: engine,
                home: home,
                maxItemsPerRoot: 200,
                maxConcurrentRoots: 2,
                overallTimeout: timeout
            )
            let summary = try scanner.streamAnalyze(scope: .userOnly, sink: collector)
            let payload = collector.payload
            let roots = RuleRootPlanner.plan(rules: [rule], home: home, scope: .userOnly).roots.count
            return RuleTrialResult(
                ruleID: rule.id,
                rootCount: roots,
                itemCount: payload.items.count,
                totalBytes: payload.items.reduce(0) { $0 + $1.sizeBytes },
                gapsCount: payload.gaps.count,
                truncated: summary.truncated || summary.cancelled
            )
        } catch {
            return RuleTrialResult(
                ruleID: rule.id,
                rootCount: 0,
                itemCount: 0,
                totalBytes: 0,
                gapsCount: 0,
                truncated: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - 文件

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        return formatter.string(from: Date())
    }
}
