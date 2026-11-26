import Foundation

/// 帮助页的本地搜索：按空白拆词，所有词都要命中标题、关键词或正文之一。
public enum HelpSearch {
    public static func matches(query: String, title: String, keywords: String, body: String) -> Bool {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = "\(title)\n\(keywords)\n\(body)".localizedLowercase
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}
