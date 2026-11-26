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

    /// V0.9.33 雪签：新增样本导出器（`xue.sample/v1`），在本机完成路径模板化与
    /// 文本脱敏，只输出区间与占位符。不新增删除能力，不改 4B 模型，不联网。
    public static let current = AppVersion(
        number: "0.9.33",
        codeName: "雪签",
        stage: "样本导出与脱敏",
        devTag: nil
    )
}
