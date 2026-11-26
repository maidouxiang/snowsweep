import Foundation

public struct SoftwareGraphScanOptions: Sendable {
    public var appRoots: [URL]
    public var home: URL
    public var launchRoots: [URL]
    public var maxAppDepth: Int
    public var maxPluginDepth: Int
    public var maxEntriesPerRoot: Int
    public var maxSpotlightLookups: Int
    public var maxSizeLookups: Int
    public var readPackageReceipts: Bool
    public var readLastUsed: Bool
    public var readCodeSignatures: Bool
    public var computeSizes: Bool

    public init(appRoots: [URL], home: URL, launchRoots: [URL],
                maxAppDepth: Int = 3, maxPluginDepth: Int = 1,
                maxEntriesPerRoot: Int = 400,
                maxSpotlightLookups: Int = 200, maxSizeLookups: Int = 120,
                readPackageReceipts: Bool = true, readLastUsed: Bool = true,
                readCodeSignatures: Bool = false, computeSizes: Bool = true) {
        self.appRoots = appRoots
        self.home = home
        self.launchRoots = launchRoots
        self.maxAppDepth = maxAppDepth
        self.maxPluginDepth = maxPluginDepth
        self.maxEntriesPerRoot = maxEntriesPerRoot
        self.maxSpotlightLookups = maxSpotlightLookups
        self.maxSizeLookups = maxSizeLookups
        self.readPackageReceipts = readPackageReceipts
        self.readLastUsed = readLastUsed
        self.readCodeSignatures = readCodeSignatures
        self.computeSizes = computeSizes
    }

    public static func live(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> SoftwareGraphScanOptions {
        SoftwareGraphScanOptions(
            appRoots: [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                home.appendingPathComponent("Applications")
            ],
            home: home,
            launchRoots: [
                home.appendingPathComponent("Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchDaemons")
            ]
        )
    }
}

private struct AppRecord: Sendable {
    let node: SoftwareNode
    let bundleID: String
    let name: String
    let path: String
}

private final class WarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

public enum SoftwareGraphScanner {
    public static func scan(store: SoftwareFamilyStore,
                            options: SoftwareGraphScanOptions = .live()) -> SoftwareGraphReport {
        let warnings = WarningBox()
        let apps = installedApps(store: store, options: options, warnings: warnings)
        let packages = options.readPackageReceipts ? packageReceipts() : []
        let launchLabels = launchLabels(options: options)

        var nodes: [SoftwareNode] = []
        var edges: [SoftwareEdge] = []
        var seenNodeIDs = Set<String>()

        for family in store.families {
            let node = SoftwareNode(
                id: "family:\(family.id)",
                name: family.name,
                path: "family:\(family.id)",
                kind: .family,
                familyID: family.id,
                familyName: family.name,
                isProtected: !family.protectedTokens.isEmpty
            )
            if seenNodeIDs.insert(node.id).inserted { nodes.append(node) }
        }

        for app in apps {
            if seenNodeIDs.insert(app.node.id).inserted { nodes.append(app.node) }
            if let familyID = app.node.familyID {
                edges.append(SoftwareEdge(
                    from: app.node.id,
                    to: "family:\(familyID)",
                    relation: .belongsTo,
                    evidence: SoftwareEvidence(
                        kind: .bundleIdentifier,
                        value: app.bundleID,
                        strength: .strong,
                        note: "应用 Bundle ID 命中 \(app.node.familyName ?? familyID)"
                    )
                ))
            }
        }

        var candidateNodes: [SoftwareNode] = []
        for family in store.families {
            for root in family.expandedPluginRoots(home: options.home) {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                let entries = pluginEntries(root: root, options: options, warnings: warnings)
                for entry in entries {
                    let bundleID = bundleIdentifier(at: entry)
                    let kind = nodeKind(for: entry)
                    // 插件可能装在宿主家族的根里，但自己属于另一个厂商。
                    // 先按 Bundle ID 找真正的家族，找不到才退回插件根所属家族。
                    let entryFamily = bundleID.flatMap { store.family(matchingBundleID: $0) } ?? family
                    let protected = entryFamily.containsProtectedToken(entry.path)
                        || family.containsProtectedToken(entry.path)
                        || kind == .license
                        || entry.path.hasPrefix("/System/")
                    let node = SoftwareNode(
                        id: entry.path,
                        name: entry.lastPathComponent,
                        path: entry.path,
                        kind: kind,
                        bundleID: bundleID,
                        familyID: entryFamily.id,
                        familyName: entryFamily.name,
                        isSystem: entry.path.hasPrefix("/System/"),
                        isProtected: protected,
                        lastModified: modificationDate(entry)
                    )
                    if seenNodeIDs.insert(node.id).inserted { nodes.append(node) }
                    if let bundleID {
                        edges.append(SoftwareEdge(
                            from: node.id,
                            to: "family:\(entryFamily.id)",
                            relation: .belongsTo,
                            evidence: SoftwareEvidence(
                                kind: .bundleIdentifier,
                                value: bundleID,
                                strength: .strong,
                                note: "Bundle ID 命中 \(entryFamily.name) 前缀"
                            )
                        ))
                    }
                    candidateNodes.append(node)
                }
            }
        }

        var findings: [SoftwareFinding] = []
        var spotlightBudget = options.maxSpotlightLookups
        var sizeBudget = options.maxSizeLookups

        for raw in candidateNodes {
            let family = store.families.first { $0.id == raw.familyID }
            let hosts = family.map { installedHosts(for: $0, apps: apps) } ?? []
            let missing = family?.hostBundleIDs.filter { id in
                !hosts.contains(where: { $0.bundleID == id })
            } ?? []
            var evidence = family.map { familyEvidence(for: $0, packages: packages, labels: launchLabels) } ?? []
            if let family, let root = family.matchingPluginRoot(for: raw.path, home: options.home) {
                evidence.append(SoftwareEvidence(
                    kind: .pluginRoot, value: root.path, strength: .strong,
                    note: "路径落在 \(family.name) 插件根"
                ))
            }
            if let bundleID = raw.bundleID {
                evidence.append(SoftwareEvidence(
                    kind: .bundleIdentifier, value: bundleID, strength: .strong,
                    note: "Bundle ID 属于 \(raw.familyName ?? "该家族")"
                ))
            }
            if hosts.count > 1 {
                evidence.append(SoftwareEvidence(
                    kind: .sharedHost, value: hosts.map(\.bundleID).joined(separator: ","),
                    strength: .strong, note: "同家族 \(hosts.count) 个宿主仍安装"
                ))
            }

            var lastUsed: Date?
            if options.readLastUsed, hosts.isEmpty, spotlightBudget > 0 {
                spotlightBudget -= 1
                lastUsed = spotlightDate(for: raw.path)
            }
            var sizeBytes: Int64?
            if options.computeSizes, hosts.isEmpty, sizeBudget > 0 {
                sizeBudget -= 1
                sizeBytes = directorySize(raw.path)
            }

            let level = verdict(for: raw, family: family, hosts: hosts,
                                evidence: evidence, lastUsed: lastUsed)
            var reasons: [String] = []
            if let family { reasons.append("命中本地族谱：\(family.name)") }
            else { reasons.append("没有命中本地族谱") }
            if hosts.isEmpty {
                if let family, !family.hostBundleIDs.isEmpty {
                    reasons.append("登记的宿主没有安装：\(missing.joined(separator: "、"))")
                } else {
                    reasons.append("族谱没有登记宿主，无法判断主人")
                }
            } else {
                reasons.append("宿主仍安装：\(hosts.map(\.name).joined(separator: "、"))")
            }
            if hosts.count > 1 { reasons.append("同家族有 \(hosts.count) 个宿主仍安装，不建议删") }
            if let lastUsed {
                let days = max(0, Int(Date().timeIntervalSince(lastUsed) / 86_400))
                reasons.append("最近使用约 \(days) 天前")
            } else if hosts.isEmpty {
                if let modified = raw.lastModified {
                    let days = max(0, Int(Date().timeIntervalSince(modified) / 86_400))
                    reasons.append("内容约 \(days) 天未修改")
                }
                reasons.append("没有读到使用记录，不能证明长期未用")
            }
            if raw.isProtected { reasons.append("路径包含许可证/系统保护词，禁止清理") }

            findings.append(SoftwareFinding(
                node: raw, familyID: raw.familyID, familyName: raw.familyName,
                installedHosts: hosts, missingHostBundleIDs: missing,
                sharedByHosts: hosts.count > 1 ? hosts : [],
                verdict: level, reasons: Array(reasons.prefix(5)), evidence: evidence,
                isShared: hosts.count > 1, isOwnerMissing: hosts.isEmpty,
                lastUsed: lastUsed, lastModified: raw.lastModified, sizeBytes: sizeBytes
            ))
        }

        findings.sort { lhs, rhs in
            if lhs.verdict.sortOrder != rhs.verdict.sortOrder {
                return lhs.verdict.sortOrder < rhs.verdict.sortOrder
            }
            if (lhs.sizeBytes ?? 0) != (rhs.sizeBytes ?? 0) {
                return (lhs.sizeBytes ?? 0) > (rhs.sizeBytes ?? 0)
            }
            return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
        }

        var stats = SoftwareGraphStats(
            appCount: apps.count, familyCount: store.families.count,
            pluginNodeCount: candidateNodes.count, warnings: warnings.all
        )
        for finding in findings {
            switch finding.verdict {
            case .suggestedCleanup:
                stats.suggestedCleanupCount += 1
                stats.totalCandidateBytes += finding.sizeBytes ?? 0
            case .possibleRedundancy:
                stats.possibleRedundancyCount += 1
                stats.totalCandidateBytes += finding.sizeBytes ?? 0
            case .keep: stats.keepCount += 1
            case .unknown: stats.unknownCount += 1
            case .protected: stats.protectedCount += 1
            }
        }

        return SoftwareGraphReport(
            schemaVersion: store.schemaVersion, generatedAt: Date(),
            storeUpdatedAt: store.updatedAt, nodes: nodes, edges: edges,
            findings: findings, stats: stats
        )
    }

    // MARK: - 应用

    private static func installedApps(store: SoftwareFamilyStore,
                                      options: SoftwareGraphScanOptions,
                                      warnings: WarningBox) -> [AppRecord] {
        var records: [AppRecord] = []
        var seenPaths = Set<String>()
        for root in options.appRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    warnings.append("读不到 \(url.path)：\(error.localizedDescription)")
                    return true
                }
            )
            while let item = enumerator?.nextObject() as? URL {
                if enumerator?.level ?? 0 > options.maxAppDepth {
                    enumerator?.skipDescendants()
                    continue
                }
                guard item.pathExtension == "app" else { continue }
                guard seenPaths.insert(item.path).inserted else {
                    enumerator?.skipDescendants()
                    continue
                }
                let bundle = Bundle(url: item)
                let info = bundle?.infoDictionary
                let display = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                let name = display?.trimmingCharacters(in: .whitespaces).isEmpty == false
                    ? display! : item.deletingPathExtension().lastPathComponent
                let bundleID = bundle?.bundleIdentifier ?? ""
                guard !bundleID.isEmpty else {
                    enumerator?.skipDescendants()
                    continue
                }
                let system = item.path.hasPrefix("/System/") || bundleID.hasPrefix("com.apple.")
                let family = store.family(matchingBundleID: bundleID)
                records.append(AppRecord(
                    node: SoftwareNode(
                        id: item.path, name: name, path: item.path, kind: .app,
                        bundleID: bundleID, familyID: family?.id,
                        familyName: family?.name, isSystem: system,
                        isProtected: system, lastModified: modificationDate(item)
                    ),
                    bundleID: bundleID, name: name, path: item.path
                ))
                enumerator?.skipDescendants()
            }
        }
        return records
    }

    // MARK: - 宿主/证据

    private static func installedHosts(for family: SoftwareFamily, apps: [AppRecord]) -> [SoftwareHost] {
        var seen = Set<String>()
        var hosts: [SoftwareHost] = []
        for app in apps {
            let exact = family.hostBundleIDs.contains(app.bundleID)
            let prefix = family.hostBundlePrefixes.contains { app.bundleID.hasPrefix($0) }
            guard exact || prefix else { continue }
            guard seen.insert(app.bundleID).inserted else { continue }
            hosts.append(SoftwareHost(bundleID: app.bundleID, name: app.name, path: app.path))
        }
        return hosts
    }

    private static func familyEvidence(for family: SoftwareFamily, packages: [String],
                                       labels: [String]) -> [SoftwareEvidence] {
        var evidence: [SoftwareEvidence] = []
        if let receipt = packages.first(where: { pkg in
            family.receiptPrefixes.contains { pkg.hasPrefix($0) }
        }) {
            evidence.append(SoftwareEvidence(
                kind: .packageReceipt, value: receipt, strength: .strong,
                note: "安装收据属于 \(family.name)"
            ))
        }
        if let label = labels.first(where: { label in
            let lower = label.lowercased()
            return family.aliases.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
                || family.bundlePrefixes.contains { lower.contains($0.lowercased()) }
        }) {
            evidence.append(SoftwareEvidence(
                kind: .launchAgent, value: label, strength: .medium,
                note: "同家族后台服务仍在"
            ))
        }
        return evidence
    }

    // MARK: - 判定

    private static func verdict(for node: SoftwareNode, family: SoftwareFamily?,
                                hosts: [SoftwareHost], evidence: [SoftwareEvidence],
                                lastUsed: Date?) -> SoftwareVerdict {
        if node.isProtected || family?.containsProtectedToken(node.path) == true {
            return .protected
        }
        if family == nil { return .unknown }
        let strong = evidence.contains { $0.strength == .strong }
        if !hosts.isEmpty { return .keep }
        guard strong else { return .unknown }
        guard let lastUsed else {
            // 没读到使用记录，不把“没记录”当“长期未用”。
            return .possibleRedundancy
        }
        let age = Date().timeIntervalSince(lastUsed)
        if age >= 180 * 86_400 { return .suggestedCleanup }
        return .possibleRedundancy
    }

    // MARK: - 插件枚举

    private static func pluginEntries(root: URL, options: SoftwareGraphScanOptions,
                                      warnings: WarningBox) -> [URL] {
        var entries: [URL] = []
        var count = 0
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                warnings.append("读不到 \(url.path)：\(error.localizedDescription)")
                return true
            }
        )
        while let item = enumerator?.nextObject() as? URL {
            if enumerator?.level ?? 0 > options.maxPluginDepth {
                enumerator?.skipDescendants()
                continue
            }
            if item.path == root.path { continue }
            let ext = item.pathExtension.lowercased()
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isBundle = ["app", "plugin", "component", "vst", "vst3", "aax", "ofx"].contains(ext)
            guard isDir || isBundle || ["pkg", "dmg", "zxp"].contains(ext) else { continue }
            entries.append(item)
            count += 1
            if count >= options.maxEntriesPerRoot {
                warnings.append("插件根 \(root.path) 超过 \(options.maxEntriesPerRoot) 项，已截断")
                break
            }
            if ext == "app" || isBundle {
                enumerator?.skipDescendants()
            }
        }
        return entries
    }

    private static func nodeKind(for url: URL) -> SoftwareNodeKind {
        let lower = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()
        if lower.hasPrefix("licen") || path.contains("/license") || path.contains("rlm") {
            return .license
        }
        if lower.contains("cache") || path.contains("/caches/") {
            return .cache
        }
        if lower.contains("helper") || lower.contains("daemon") || lower.contains("agent") {
            return .helper
        }
        let ext = url.pathExtension.lowercased()
        if ["pkg", "dmg", "zxp"].contains(ext) { return .installer }
        if ["plugin", "component", "vst", "vst3", "aax", "ofx", "app"].contains(ext) {
            return .plugin
        }
        return .plugin
    }

    private static func bundleIdentifier(at url: URL) -> String? {
        if url.pathExtension.lowercased() == "app" {
            return Bundle(url: url)?.bundleIdentifier
        }
        let info = url.appendingPathComponent("Contents/Info.plist")
        let alt = url.appendingPathComponent("Info.plist")
        for candidate in [info, alt] {
            guard let data = try? Data(contentsOf: candidate),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                  ) as? [String: Any],
                  let id = plist["CFBundleIdentifier"] as? String,
                  !id.isEmpty else { continue }
            return id
        }
        return nil
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    // MARK: - 外部只读证据

    private static func packageReceipts() -> [String] {
        let result = run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 5)
        guard result.status == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func launchLabels(options: SoftwareGraphScanOptions) -> [String] {
        var labels: [String] = []
        for root in options.launchRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for item in children where item.pathExtension == "plist" {
                if let label = plistLabel(item) { labels.append(label) }
            }
        }
        return labels
    }

    private static func plistLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let label = plist["Label"] as? String,
              !label.isEmpty else { return url.deletingPathExtension().lastPathComponent }
        return label
    }

    private static func spotlightDate(for path: String) -> Date? {
        let result = run("/usr/bin/mdls", ["-name", "kMDItemLastUsedDate", "-raw", path], timeout: 2)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != "(null)", !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }

    private static func directorySize(_ path: String) -> Int64? {
        let result = run("/usr/bin/du", ["-sk", path], timeout: 3)
        guard result.status == 0,
              let first = result.output.split(separator: "\t").first,
              let kb = Int64(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return kb * 1024
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ executable: String, _ args: [String],
                            timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: timedOut ? -2 : process.terminationStatus, output: output)
    }
}
