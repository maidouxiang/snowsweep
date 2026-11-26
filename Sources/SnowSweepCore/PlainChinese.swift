import Foundation

/// V0.8.0：中文直白化的唯一检查口径。只做提示与自检，不参与删除判定。
public enum PlainChinese {
    public static let forbiddenWords = ["旨在", "用于", "从而", "进行", "将会", "请勿"]
    public static let sentenceLimit = 40

    public static func forbiddenHits(in text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    public static func isWithinLength(_ text: String) -> Bool {
        text.count <= sentenceLimit
    }

    public static func isPlain(_ text: String) -> Bool {
        forbiddenHits(in: text).isEmpty && isWithinLength(text)
    }
}
