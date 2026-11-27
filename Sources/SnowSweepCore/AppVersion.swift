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

    /// V0.9.35 雪集：规则缺失报告页新增“导出样本包（脱敏）”入口，
    /// 一键生成 `xue.sample/v1` zip；导出逻辑与命令行共用 `SampleExporter`。
    /// 不新增删除能力，不改 4B 模型，不联网。
    public static let current = AppVersion(
        number: "0.9.35",
        codeName: "雪集",
        stage: "应用内样本导出入口",
        devTag: nil
    )
}
