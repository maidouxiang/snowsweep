import SwiftUI
import AppKit

/// 雪日 / 雪夜两套外观。值写入 `snow.appearance`，旧值保持兼容。
enum SnowTheme: String, CaseIterable, Identifiable {
    case snowDay
    case snowNight

    var id: String { rawValue }

    var chineseName: String {
        switch self {
        case .snowDay: "雪日"
        case .snowNight: "雪夜"
        }
    }

    var detail: String {
        switch self {
        case .snowDay: "雪原白为底，冰蓝为字；白天默认，长时间看盘也不刺眼。"
        case .snowNight: "深墨蓝为底，霜白为字；夜里降低亮度，不是旧黑金。"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .snowDay: .light
        case .snowNight: .dark
        }
    }
}

/// 语义色板。按系统外观解析，主题通过 `preferredColorScheme` 切换。
enum SnowSkin {
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dynamic(light: "#F4F8FB", dark: "#0D151E")
    static let panel = dynamic(light: "#FFFFFF", dark: "#15212C")
    static let panelStrong = dynamic(light: "#FFFFFF", dark: "#1A2835")
    static let field = dynamic(light: "#FFFFFF", dark: "#1A2A36")
    static let accent = dynamic(light: "#3F708C", dark: "#7FB3CC")
    static let gold = accent
    static let goldDim = accent.opacity(0.12)
    static let text = dynamic(light: "#16232E", dark: "#E7EEF4")
    static let dim = dynamic(light: "#5E6F7D", dark: "#9EAEBB")
    static let faint = dynamic(light: "#71808C", dark: "#83929E")
    static let hairline = dynamic(light: "#DCE5EC", dark: "#263440")
    static let fieldBorder = dynamic(light: "#DCE5EC", dark: "#2A3A48")
    static let onAccent = dynamic(light: "#FFFFFF", dark: "#0D151E")
    static let green = dynamic(light: "#2E7D6E", dark: "#62B29F")
    static let orange = dynamic(light: "#A96F1F", dark: "#D0A052")
    static let danger = dynamic(light: "#A33A32", dark: "#D06A5E")
    static let snowStroke = dynamic(light: "#B9D2E0", dark: "#7FB3CC")
    static let snowShadow = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(isDark ? 0.38 : 0.12)
    })

    static func overlay(_ alpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value: CGFloat = isDark ? 1 : 0
            return NSColor(srgbRed: value, green: value, blue: value, alpha: alpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
