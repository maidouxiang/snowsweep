import Foundation

/// 英文原始名 → 中文标识 + 一句人话。
/// 这是「看得懂」规则的单一事实来源：界面只显示中文，英文路径折叠在后面。
public struct GlossaryEntry: Codable, Hashable, Sendable {
    public let en: String
    public let zh: String
    public let say: String

    public init(en: String, zh: String, say: String) {
        self.en = en
        self.zh = zh
        self.say = say
    }
}

public struct Glossary: Sendable {
    public let version: String
    public let entries: [GlossaryEntry]

    private struct FileFormat: Decodable {
        let version: String
        let terms: [GlossaryEntry]
    }

    public enum GlossaryError: Error, LocalizedError {
        case notFound
        case duplicateTerm(String)
        case emptyField(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: return "找不到中文标识词典 Rules/glossary.json"
            case let .duplicateTerm(term): return "词典存在重复词条（不区分大小写）：\(term)"
            case let .emptyField(term): return "词条 \(term) 的中文名或解释为空"
            }
        }
    }

    public init(version: String, entries: [GlossaryEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            let key = entry.en.lowercased()
            guard seen.insert(key).inserted else { throw GlossaryError.duplicateTerm(entry.en) }
            guard !entry.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GlossaryError.emptyField(entry.en)
            }
        }
        self.version = version
        self.entries = entries
    }

    public init(jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let file = try JSONDecoder().decode(FileFormat.self, from: data)
        try self.init(version: file.version, entries: file.terms)
    }

    /// 开发/测试环境直接从工程目录读取；打包 App 时应由上层从 Bundle 注入 URL。
    public static func loadBundled() throws -> Glossary {
        var candidates: [URL] = []
        // SwiftPM 资源随模块打包，Xcode App Bundle 下也能找到。
        if let moduleResource = Bundle.module.url(forResource: "glossary", withExtension: "json") {
            candidates.append(moduleResource)
        }
        if let bundled = Bundle.main.url(forResource: "glossary", withExtension: "json", subdirectory: "Rules") {
            candidates.append(bundled)
        }
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rules/glossary.json"))
        candidates.append(URL(fileURLWithPath: "Rules/glossary.json"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try Glossary(jsonURL: url)
        }
        throw GlossaryError.notFound
    }

    /// 命中该路径的所有词条。越靠后的路径段越具体，排在前面；
    /// 同一位置时英文更长者在前，避免 "Library" 抢走 "Caches" 的解释。
    public func terms(in path: String) -> [GlossaryEntry] {
        func position(_ term: String) -> Int {
            guard let range = path.range(of: term, options: .caseInsensitive) else { return -1 }
            return path.distance(from: path.startIndex, to: range.lowerBound)
        }
        return entries.filter { path.localizedCaseInsensitiveContains($0.en) }.sorted { lhs, rhs in
            let lp = position(lhs.en)
            let rp = position(rhs.en)
            if lp != rp { return lp > rp }
            return lhs.en.count > rhs.en.count
        }
    }

    /// 界面上显示的中文名。没有命中词条时明确写「其他项目」，不把英文原文丢给用户。
    public func chineseLabel(for path: String) -> String {
        terms(in: path).first?.zh ?? "其他项目"
    }

    /// 一句人话解释。最多拼两条，避免界面变成一长串。
    public func humanExplanation(for path: String) -> String {
        let says = Array(terms(in: path).prefix(2).map(\.say))
        return says.isEmpty ? "规则已判定，未找到对应中文词条，请展开查看原始路径。" : says.joined(separator: "；")
    }
}
