import Foundation

/// 版本身份的单一事实来源。UI 与命令行脚本都读这里，不各自写死字符串。
public struct AppVersion: Codable, Hashable, Sendable {
    public let number: String
    public let codeName: String
    public let stage: String
    public let devTag: String?

    public init(number: String, codeName: String, stage: String, devTag: String? = nil) {
        self.number = number
        self.codeName = codeName
        self.stage = stage
        self.devTag = devTag
    }

    public var display: String { "V\(number) · \(codeName)" }

    public var fullDisplay: String {
        guard let devTag, !devTag.isEmpty else { return display }
        return "\(display)（\(devTag)）"
    }

    /// V0.9.34 雪滤：修正样本导出把“未提供具体路径”这类句子误当成路径、
    /// 模板化成 `<name>` 的问题；只收 `/`、`~/` 开头的真实路径。
    /// 不新增删除能力，不改 4B 模型，不联网。
    public static let current = AppVersion(
        number: "0.9.34",
        codeName: "雪滤",
        stage: "样本路径过滤修正",
        devTag: nil
    )
}
