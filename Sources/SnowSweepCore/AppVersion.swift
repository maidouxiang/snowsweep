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

    /// V0.9.32 雪敛：主窗口关闭后菜单栏快捷面板不再沿用已释放的空快照；
    /// 每次展开立即取数，展开期间定时刷新，并接入物理接口每秒上下行速率。
    /// 不新增删除能力，不改 4B 模型。
    public static let current = AppVersion(
        number: "0.9.32",
        codeName: "雪敛",
        stage: "菜单栏实时面板与上下行网速",
        devTag: nil
    )
}
