import CryptoKit
import Foundation

// MARK: - 样本模式

/// V1 样本包的唯一协议标识。任何字段增删都必须升版本，不允许悄悄改语义。
public enum SampleSchema: Sendable {
    public static let v1 = "xue.sample/v1"
    public static let sampleLicense = "CC0-1.0"
    public static let bundleReadmeName = "README.txt"
    public static let sampleFileName = "sample.json"
    public static let manifestFileName = "manifest.json"
    public static let summaryFileName = "scan-summary.json"
}

// MARK: - 数据结构

public struct SampleAppInfo: Codable, Sendable, Hashable {
    public let version: String
    public let build: String
    public let bundleId: String
}

public struct SampleHostInfo: Codable, Sendable, Hashable {
    public let macOS: String
    public let arch: String
    public let locale: String
}

public struct SampleRuleInfo: Codable, Sendable, Hashable {
    public let version: String
    public let sha256: String
}

public struct SampleIntent: Codable, Sendable, Hashable {
    public let category: String
    /// 已脱敏并截断的原话；无法安全脱敏时为空字符串，只保留 `category`。
    public let queryRedacted: String
}

public struct SampleObservation: Codable, Sendable, Hashable {
    public let scope: [String]
    public let coverage: Double
    public let fileCountBucket: String
    public let bytesBucket: String
}

public struct SamplePathEntry: Codable, Sendable, Hashable {
    public let pattern: String
    public let role: String          // observed / protected / rule
    public let protected: Bool
}

public struct SampleVerdict: Codable, Sendable, Hashable {
    public let result: String
    public let closestRules: [String]
    public let evidence: [String]
}

public struct SampleConsent: Codable, Sendable, Hashable {
    public let sampleLicense: String
    public let publicSample: Bool
    public let rawPaths: Bool
    public let screenshots: Bool
}

/// 一份 `xue.sample/v1`。字段顺序与公开文档一致，序列化时按键名排序。
public struct XueSample: Codable, Sendable {
    public let schema: String
    public let sampleId: String
    public let createdAt: Date
    public let app: SampleAppInfo
    public let host: SampleHostInfo
    public let rules: SampleRuleInfo
    public let intent: SampleIntent
    public let observation: SampleObservation
    public let paths: [SamplePathEntry]
    public let verdict: SampleVerdict
    public let consent: SampleConsent

    public init(
        schema: String = SampleSchema.v1,
        sampleId: String = UUID().uuidString,
        createdAt: Date = Date(),
        app: SampleAppInfo,
        host: SampleHostInfo,
        rules: SampleRuleInfo,
        intent: SampleIntent,
        observation: SampleObservation,
        paths: [SamplePathEntry],
        verdict: SampleVerdict,
        consent: SampleConsent
    ) {
        self.schema = schema
        self.sampleId = sampleId
        self.createdAt = createdAt
        self.app = app
        self.host = host
        self.rules = rules
        self.intent = intent
        self.observation = observation
        self.paths = paths
        self.verdict = verdict
        self.consent = consent
    }
}

// MARK: - 分桶

/// 数量与体积只报区间。区间是规则设计的输入，精确值对维护者没有用，对用户却是信息泄露。
public enum SampleBucket: Sendable {
    public static func fileCount(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1...10: return "1-10"
        case 11...100: return "11-100"
        case 101...1000: return "101-1000"
        default: return "1000+"
        }
    }

    public static func bytes(_ bytes: Int64) -> String {
        let mb: Int64 = 1024 * 1024
        let gb: Int64 = 1024 * mb
        switch bytes {
        case ..<0: return "0"
        case 0: return "0"
        case 1..<mb: return "<1MB"
        case mb..<(100 * mb): return "1-100MB"
        case (100 * mb)..<gb: return "100MB-1GB"
        case gb..<(5 * gb): return "1-5GB"
        default: return "5GB+"
        }
    }

    public static func coverage(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, 0), 1) * 100).rounded() / 100
    }
}

// MARK: - 脱敏

/// 样本脱敏器。与 `ReportRedactor` 的分工：
/// - `ReportRedactor` 给自己看报告用，只收敛用户名；
/// - 本类型用于导出到公开渠道，凡是"能指向某个人或某份文件"的都换成占位符。
public struct SampleRedactor: Sendable {
    public let home: String

    /// 系统目录名保留，否则样本退化成一串 `<name>`，维护者无法判断规则该写在哪。
    private static let structuralSegments: Set<String> = [
        "~", "Library", "Caches", "Containers", "Group Containers", "Application Support",
        "Logs", "Preferences", "Application Scripts", "Saved Application State",
        "LaunchAgents", "LaunchDaemons", "Frameworks", "PlugIns", "Extensions",
        "Movies", "Music", "Pictures", "Documents", "Downloads", "Desktop", "Public",
        "System", "Users", "Volumes", "tmp", "private", "var", "etc", "opt", "usr",
        "Caches", "WebKit", "HTTPStorages", "WebKitCache", "Daemon Containers"
    ]

    /// 反向域名前缀，用于识别应用标识（如 `com.tencent.xinWeChat`）。
    private static let reverseDomainPrefixes: Set<String> = [
        "com", "org", "net", "io", "cn", "dev", "app", "me", "co", "xyz", "jp", "de", "uk"
    ]

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public static var `default`: SampleRedactor { SampleRedactor() }

    // MARK: 路径模板化

    /// 把绝对路径变成可公开的模板：`/Users/example/Library/Caches/com.a.b/9f3…` → `~/Library/Caches/com.a.b/<hash>`。
    public func template(_ path: String) -> String {
        var working = path
        if !home.isEmpty {
            let homePrefix = home.hasSuffix("/") ? String(home.dropLast()) : home
            working = working.replacingOccurrences(of: homePrefix + "/", with: "~/")
            if working.hasPrefix(homePrefix) {
                working = "~" + String(working.dropFirst(homePrefix.count))
            }
        }

        let isAbsolute = working.hasPrefix("/")
        var segments = working.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        segments.removeAll { $0.isEmpty }

        var output: [String] = []
        for (index, raw) in segments.enumerated() {
            let segment = scrubInline(raw)
            if segment == "~" {
                output.append("~")
                continue
            }
            if Self.structuralSegments.contains(segment) {
                output.append(segment)
                continue
            }
            if Self.isReverseDomainIdentifier(segment) {
                output.append(segment)
                continue
            }
            if index == 0, segment == "Users" { output.append(segment); continue }
            if Self.looksOpaque(segment) {
                output.append("<hash>")
                continue
            }
            if let ext = fileExtension(of: segment) {
                output.append("<name>.\(ext)")
                continue
            }
            output.append("<name>")
        }

        var result = output.joined(separator: "/")
        if isAbsolute { result = "/" + result }
        // 不合并相邻占位符：`<name>/<name>` 恰好说明"目录里还有文件"，合并会丢掉一层结构。
        return result
    }

    /// 同一角色的多条路径往往只有最后一段不同，合并后样本更干净。
    public func templates(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let value = template(path)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    // MARK: 文本脱敏

    private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    private static let ipv4Pattern = #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    private static let macPattern = #"\b[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}\b"#
    private static let phonePattern = #"(?<!\d)1[3-9]\d{9}(?!\d)"#
    private static let hexPattern = #"\b[0-9a-fA-F]{16,}\b"#
    private static let longDigitsPattern = #"(?<!\d)(?:\d[ -]?){6,}\d(?!\d)"#

    /// 一段自由文本的脱敏：邮箱、手机号、UUID、IP、MAC、长十六进制、长数字全部换成占位符。
    public func scrub(_ text: String) -> String {
        var working = templateIfPath(text)
        let rules: [(String, String)] = [
            (Self.uuidPattern, "<id>"),
            (Self.emailPattern, "<id>"),
            (Self.macPattern, "<id>"),
            (Self.ipv4Pattern, "<id>"),
            (Self.phonePattern, "<id>"),
            (Self.hexPattern, "<hash>"),
            (Self.longDigitsPattern, "<id>")
        ]
        for (pattern, replacement) in rules {
            working = Self.replace(pattern, in: working, with: replacement)
        }
        return working
    }

    /// 用户原话：先脱敏再截断。脱敏后仍像"具体人名/具体文件"的句子直接不导出，返回 nil。
    public func safeQuery(_ query: String, maxLength: Int = 60) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scrubbed = scrub(trimmed)
        // 含路径一律不收：路径本身就是最容易被忽略的隐私。
        guard !scrubbed.contains("/") && !scrubbed.contains("~/") else { return nil }
        // 脱敏后仍残留连续 6 位以上数字，说明有编号没被识别，宁可不导出。
        if scrubbed.range(of: #"\d{6,}"#, options: .regularExpression) != nil { return nil }
        let clipped = scrubbed.count > maxLength ? String(scrubbed.prefix(maxLength)) + "…" : scrubbed
        return clipped
    }

    // MARK: 辅助

    private func templateIfPath(_ text: String) -> String {
        guard !home.isEmpty else { return text }
        let homePrefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard text.contains(homePrefix) else { return text }
        return text.replacingOccurrences(of: homePrefix + "/", with: "~/")
            .replacingOccurrences(of: homePrefix, with: "~")
    }

    private func scrubInline(_ segment: String) -> String {
        var value = segment
        for (pattern, replacement) in [
            (Self.uuidPattern, "<id>"),
            (Self.emailPattern, "<id>"),
            (Self.phonePattern, "<id>")
        ] {
            value = Self.replace(pattern, in: value, with: replacement)
        }
        return value
    }

    private static func isReverseDomainIdentifier(_ segment: String) -> Bool {
        let parts = segment.split(separator: ".")
        guard parts.count >= 2, let head = parts.first else { return false }
        guard reverseDomainPrefixes.contains(String(head).lowercased()) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+"))
        return segment.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func looksOpaque(_ segment: String) -> Bool {
        // 纯十六进制且长度 ≥ 16、纯数字且长度 ≥ 6、UUID 形态，都是缓存哈希或编号。
        if segment.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil { return true }
        if segment.range(of: #"^\d{6,}$"#, options: .regularExpression) != nil { return true }
        if segment.range(of: uuidPattern, options: .regularExpression) != nil { return true }
        return false
    }

    private func fileExtension(of segment: String) -> String? {
        guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else { return nil }
        let ext = String(segment[segment.index(after: dot)...])
        guard (1...6).contains(ext.count) else { return nil }
        guard ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        // 反向域名已被前面拦截，这里剩下的都是"名字.扩展名"。
        guard !ext.allSatisfy({ $0.isNumber }) else { return nil }
        return ext.lowercased()
    }


    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}

// MARK: - 样本构造

/// 一次导出需要的全部输入。刻意不含"文件列表"，只收路径与区间。
public struct SampleContext: Sendable {
    public var category: String
    public var query: String?
    public var coverage: Double
    public var fileCount: Int
    public var bytes: Int64
    public var ruleBookVersion: String
    public var ruleBookSHA256: String
    public var observedPaths: [String]
    public var protectedPaths: [String]
    public var result: String
    public var closestRuleIDs: [String]
    public var evidence: [String]

    public init(
        category: String,
        query: String? = nil,
        coverage: Double,
        fileCount: Int,
        bytes: Int64,
        ruleBookVersion: String,
        ruleBookSHA256: String,
        observedPaths: [String] = [],
        protectedPaths: [String] = [],
        result: String = "unknown",
        closestRuleIDs: [String] = [],
        evidence: [String] = []
    ) {
        self.category = category
        self.query = query
        self.coverage = coverage
        self.fileCount = fileCount
        self.bytes = bytes
        self.ruleBookVersion = ruleBookVersion
        self.ruleBookSHA256 = ruleBookSHA256
        self.observedPaths = observedPaths
        self.protectedPaths = protectedPaths
        self.result = result
        self.closestRuleIDs = closestRuleIDs
        self.evidence = evidence
    }
}

public enum SampleExporter: Sendable {
    public static func sample(
        from context: SampleContext,
        redactor: SampleRedactor = .default,
        appVersion: AppVersion = .current,
        bundleId: String = "com.selfuse.xue",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        arch: String = currentArch,
        locale: String = Locale.current.identifier,
        now: Date = Date()
    ) -> XueSample {
        let observed = redactor.templates(context.observedPaths)
        let protected = redactor.templates(context.protectedPaths)
        let entries: [SamplePathEntry] =
            observed.map { SamplePathEntry(pattern: $0, role: "observed", protected: false) } +
            protected.map { SamplePathEntry(pattern: $0, role: "protected", protected: true) }

        return XueSample(
            sampleId: UUID().uuidString,
            createdAt: now,
            app: SampleAppInfo(
                version: appVersion.number,
                build: appVersion.number,
                bundleId: bundleId
            ),
            host: SampleHostInfo(
                macOS: shortMacOS(macOSVersion),
                arch: arch,
                locale: locale
            ),
            rules: SampleRuleInfo(
                version: context.ruleBookVersion,
                sha256: context.ruleBookSHA256
            ),
            intent: SampleIntent(
                category: context.category,
                queryRedacted: context.query.flatMap { redactor.safeQuery($0) } ?? ""
            ),
            observation: SampleObservation(
                scope: observed,
                coverage: SampleBucket.coverage(context.coverage),
                fileCountBucket: SampleBucket.fileCount(context.fileCount),
                bytesBucket: SampleBucket.bytes(context.bytes)
            ),
            paths: entries,
            verdict: SampleVerdict(
                result: context.result,
                closestRules: context.closestRuleIDs,
                evidence: context.evidence.map { redactor.scrub($0) }
            ),
            consent: SampleConsent(
                sampleLicense: SampleSchema.sampleLicense,
                publicSample: true,
                rawPaths: false,
                screenshots: false
            )
        )
    }

    /// 从应用里现成的"规则缺失报告"派生一份样本，不额外扫描、不新增权限。
    public static func sample(
        from unknownCase: UnknownCase,
        ruleBookVersion: String,
        ruleBookSHA256: String,
        fileCount: Int = 0,
        bytes: Int64 = 0,
        coverage: Double = 0,
        category: String = "unknown",
        redactor: SampleRedactor = .default,
        now: Date = Date()
    ) -> XueSample {
        let context = SampleContext(
            category: category,
            query: unknownCase.query,
            coverage: coverage,
            fileCount: fileCount,
            bytes: bytes,
            ruleBookVersion: ruleBookVersion,
            ruleBookSHA256: ruleBookSHA256,
            observedPaths: unknownCase.observedPaths,
            result: "unknown",
            closestRuleIDs: unknownCase.closestRules.map(\.id),
            evidence: [unknownCase.reason]
        )
        return sample(from: context, redactor: redactor, now: now)
    }

    // MARK: 写包

    /// 写出一份样本目录：`sample.json`、`scan-summary.json`、`manifest.json`、`README.txt`。
    /// 目录里不写任何原始路径，摘要文件只放区间。
    @discardableResult
    public static func write(_ sample: XueSample, to directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(sample).write(to: directory.appendingPathComponent(SampleSchema.sampleFileName))

        let summary = ScanSummary(
            scannedAt: sample.createdAt,
            coverage: sample.observation.coverage,
            fileCountBucket: sample.observation.fileCountBucket,
            bytesBucket: sample.observation.bytesBucket,
            result: sample.verdict.result,
            schema: sample.schema,
            sampleId: sample.sampleId
        )
        try encoder.encode(summary).write(to: directory.appendingPathComponent(SampleSchema.summaryFileName))

        try Data(bundleReadme(sample).utf8)
            .write(to: directory.appendingPathComponent(SampleSchema.bundleReadmeName))

        let manifest = try manifest(for: sample, directory: directory)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(SampleSchema.manifestFileName))
        return directory
    }

    public struct ScanSummary: Codable, Sendable {
        public let scannedAt: Date
        public let coverage: Double
        public let fileCountBucket: String
        public let bytesBucket: String
        public let result: String
        public let schema: String
        public let sampleId: String
    }

    public struct ManifestFile: Codable, Sendable {
        public let name: String
        public let bytes: Int
        public let sha256: String
    }

    public struct Manifest: Codable, Sendable {
        public let schema: String
        public let sampleId: String
        public let createdAt: Date
        public let license: String
        public let files: [ManifestFile]
    }

    private static func manifest(for sample: XueSample, directory: URL) throws -> Manifest {
        let names = [SampleSchema.sampleFileName, SampleSchema.summaryFileName, SampleSchema.bundleReadmeName]
        var files: [ManifestFile] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            files.append(
                ManifestFile(
                    name: name,
                    bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            )
        }
        return Manifest(
            schema: sample.schema,
            sampleId: sample.sampleId,
            createdAt: sample.createdAt,
            license: SampleSchema.sampleLicense,
            files: files
          )
    }

    public static func bundleReadme(_ sample: XueSample) -> String {
        """
        雪 · 样本包（\(sample.schema)）
        ============================

        这份包由「雪」在本机自动脱敏生成，可以直接贴到 GitHub issue 或作为附件上传。

        包含：
        - sample.json        规则样本本体（路径已模板化、原话已脱敏）
        - scan-summary.json  扫描摘要（只保留数量/体积区间）
        - manifest.json      文件清单与 SHA-256 校验值
        - README.txt         本文件

        不包含：
        - 原始路径、文件名、文件哈希、文件内容
        - 截图（除非你手动勾选并自行打码）
        - 任何账号、邮箱、手机号、IP、序列号

        提交前请自己再扫一眼 sample.json。如果你在里面看到任何能指向你个人或你文件的内容，
        请不要上传，并把这份包留在本地。

        许可：\(SampleSchema.sampleLicense)。提交即表示同意以该许可公开这份脱敏样本。
        """
    }

    public static var currentArch: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func shortMacOS(_ version: String) -> String {
        // "Version 26.0.1 (Build ...)" → "26.0.1"
        if let range = version.range(of: #"\d+(\.\d+){1,2}"#, options: .regularExpression) {
            return String(version[range])
        }
        return version
    }

    /// 规则库校验值。样本里带上它，维护者才知道这条样本对应哪一版规则。
    public static func ruleBookDigest(at url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
