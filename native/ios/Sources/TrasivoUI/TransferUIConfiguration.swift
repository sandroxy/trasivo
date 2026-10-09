#if os(iOS)
import UIKit

public enum TransferLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en", japanese = "ja"
}

public struct TransferTheme {
    public var primary, background, surface, text, mutedText, border, success, danger: UIColor
    public init(primary: UIColor = color(0x1F7A8C), background: UIColor = color(0xF7F8FA),
                surface: UIColor = .white, text: UIColor = color(0x171A1F), mutedText: UIColor = color(0x667085),
                border: UIColor = color(0xD7DEE6), success: UIColor = color(0x14855F), danger: UIColor = color(0xC24132)) {
        self.primary = primary; self.background = background; self.surface = surface; self.text = text
        self.mutedText = mutedText; self.border = border; self.success = success; self.danger = danger
    }
    public static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

public struct TransferUIConfiguration {
    public var language: TransferLanguage
    public var theme: TransferTheme
    public var title: String?
    public init(language: TransferLanguage = .simplifiedChinese, theme: TransferTheme = TransferTheme(), title: String? = nil) {
        self.language = language; self.theme = theme; self.title = title
    }
    func text(_ key: String) -> String { Strings.values[language.rawValue]![key] ?? Strings.values[language.rawValue]!["operation_failed"]! }
    var displayTitle: String { title ?? text("title") }
    func error(_ code: String?) -> String { text((code ?? "").hasPrefix("http_") ? "http_error" : code ?? "operation_failed") }
    func bytes(_ count: Int64) -> String {
        if count < 0 { return text("unknown") }
        if count < 1024 { return "\(count) B" }
        let units = ["KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = Double(count) / 1024, unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: language.rawValue)
        formatter.minimumFractionDigits = 1; formatter.maximumFractionDigits = 1
        return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) \(units[unit])"
    }
}
#endif
