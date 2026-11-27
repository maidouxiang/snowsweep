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

    /// V0.9.36 雪发：把「打 tag → 云端构建 → 自动发布安装包」接通，
    /// 并修掉新编译器下无法通过的两处写法（树图单元格修饰链、闭包内可选简写绑定）。
    /// 不改判定逻辑、不改规则库、不联网。
    public static let current = AppVersion(
        number: "0.9.36",
        codeName: "雪发",
        stage: "发版流水线",
        devTag: nil
    )
}
