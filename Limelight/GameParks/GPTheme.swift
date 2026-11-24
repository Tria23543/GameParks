//
//  GPTheme.swift
//  GameParks
//
//  Design tokens taken from the approved GameParks design:
//  near-black background, panel surfaces, cyan (sky blue) accent.
//

import UIKit

enum GPTheme {
    // Colours (exact values from the approved design)
    static let bg = UIColor(hex: 0x05060A)
    static let panel = UIColor(hex: 0x10131D)
    static let panel2 = UIColor(hex: 0x171B29)
    static let line = UIColor(hex: 0x232839)
    static let ink = UIColor(hex: 0xF4F6FC)
    static let mut = UIColor(hex: 0x9AA3BA)
    static let dim = UIColor(hex: 0x69718C)
    static let accent = UIColor(hex: 0x3FD8F2)      // cyan / sky blue — Glenda's pick
    static let accentInk = UIColor(hex: 0x06222A)
    static let accentSoft = UIColor(hex: 0x3FD8F2, alpha: 0.13)
    static let live = UIColor(hex: 0x3DDC74)
    static let danger = UIColor(hex: 0xFF5D7A)

    // Fonts: Sora for display, Manrope for body (bundled), system font as fallback.
    static func display(_ size: CGFloat, weight: FontWeight = .bold) -> UIFont {
        let name: String
        switch weight {
        case .semibold: name = "Sora-SemiBold"
        case .bold: name = "Sora-Bold"
        case .extrabold: name = "Sora-ExtraBold"
        default: name = "Sora-SemiBold"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight.systemWeight)
    }

    static func body(_ size: CGFloat, weight: FontWeight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .semibold: name = "Manrope-SemiBold"
        case .bold: name = "Manrope-Bold"
        case .extrabold: name = "Manrope-ExtraBold"
        default: name = "Manrope-Regular"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight.systemWeight)
    }

    enum FontWeight {
        case regular, semibold, bold, extrabold
        var systemWeight: UIFont.Weight {
            switch self {
            case .regular: return .regular
            case .semibold: return .semibold
            case .bold: return .bold
            case .extrabold: return .heavy
            }
        }
    }
}

extension UIColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

extension UIView {
    func round(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.masksToBounds = true
    }
}

func GPLabel(_ text: String, font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = lines
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

/// Formats a duration in seconds the way the design shows playtime ("12.4 h", "24 min").
func GPFormatPlaytime(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        // A real (recorded) short session must not read as zero.
        return seconds > 0 ? "<1 min" : "0 min"
    }
    let hours = seconds / 3600.0
    if hours >= 1 {
        // POSIX locale: the design's "12.4 h" must not become "12,4 h"
        // in comma-decimal locales.
        return String(format: "%.1f h", locale: Locale(identifier: "en_US_POSIX"), hours)
    }
    return "\(Int(seconds / 60)) min"
}

/// "Yesterday", "2 days ago", "12 Nov" style relative dates for the game page.
func GPFormatLastPlayed(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return "Today"
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday"
    }
    let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
    if days > 1 && days < 30 {
        return "\(days) days ago"
    }
    let formatter = DateFormatter()
    // Include the year for older dates: "12 Nov" alone cannot be
    // told apart from the same date last year.
    formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
    return formatter.string(from: date)
}
