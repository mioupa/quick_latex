import Foundation

/// UserDefaults access shared by the GUI and the headless CLI.
enum AppSettings {
    static let bundleID = "local.quicklatex"

    static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }()

    enum Key {
        static let source = "source"
        static let mode = "mode"
        static let color = "color"
        static let fontSize = "fontSize"
        static let padding = "padding"
        static let preamble = "preamble"
        static let hideAfterCopy = "hideAfterCopy"
        static let texBinPath = "texBinPath"
    }

    static let defaultPreamble = #"""
    \usepackage{amsmath,amssymb}
    \usepackage{mathtools}
    \usepackage{empheq}
    \usepackage{bm}
    \usepackage{mathrsfs}
    \usepackage{xcolor}
    % よく使うがデフォルトでは無効（必要ならコメントを外す）
    % \usepackage{physics}
    % \usepackage{siunitx}
    """#

    static let defaultColorHex = "000000"
    static let defaultFontSize = 20.0
    static let defaultPadding = 2.0
    static let fontSizeRange = 4.0...200.0

    static var storedTeXBinPath: String {
        defaults.string(forKey: Key.texBinPath) ?? ""
    }
}

enum RenderMode: String, CaseIterable, Identifiable {
    case display, inline, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "数式"
        case .inline: return "インライン"
        case .text: return "テキスト"
        }
    }
}

/// Everything that affects the TeX run (font size / padding are applied afterwards in Swift).
struct RenderInput: Equatable {
    var source: String
    var mode: RenderMode
    var colorHex: String
    var preamble: String
    var texBinPath: String
}

enum HexColor {
    static func parse(_ s: String) -> (r: Double, g: Double, b: Double)? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func normalized(_ s: String) -> String? {
        guard let c = parse(s) else { return nil }
        return String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    static func luminance(_ s: String) -> Double {
        guard let c = parse(s) else { return 0 }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// "0.8157" style, always with '.' regardless of locale.
    static func texComponent(_ v: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}
