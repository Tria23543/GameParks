//
//  GPTheme.swift
//  GameParks
//
//  Design tokens for the approved design: near-black background,
//  two panel tones, cyan accent, Sora for display text and Manrope
//  for body text. Nothing here talks to the engine.
//

import UIKit

extension UIColor {
    convenience init(gpHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

enum GPColor {
    static let background = UIColor(gpHex: 0x05060A)
    static let panel = UIColor(gpHex: 0x10131D)
    static let panelRaised = UIColor(gpHex: 0x171B29)
    static let accent = UIColor(gpHex: 0x3FD8F2)
    static let onAccent = UIColor(gpHex: 0x04222B)
    static let textPrimary = UIColor.white
    static let textSecondary = UIColor(gpHex: 0x9AA7BD)
    static let textFaint = UIColor(gpHex: 0x5D6B82)
    static let success = UIColor(gpHex: 0x3DDC84)
    static let warning = UIColor(gpHex: 0xFFC24B)
    static let danger = UIColor(gpHex: 0xFF6B6B)
    static let separator = UIColor(gpHex: 0x232A3D)
}

enum GPFont {
    enum Weight {
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

    static func display(_ size: CGFloat, weight: Weight = .bold) -> UIFont {
        let name: String
        switch weight {
        // A-84: no Sora-Regular is bundled; the lightest Sora that
        // actually ships is SemiBold, so .regular honestly maps to
        // it instead of silently returning Bold.
        case .regular, .semibold: name = "Sora-SemiBold"
        case .bold: name = "Sora-Bold"
        case .extrabold: name = "Sora-ExtraBold"
        }
        let base = UIFont(name: name, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
        // A-94: scale with the user's text-size setting, keeping the
        // design size as the default-size base.
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    static func body(_ size: CGFloat, weight: Weight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .regular: name = "Manrope-Regular"
        case .semibold: name = "Manrope-SemiBold"
        case .bold: name = "Manrope-Bold"
        case .extrabold: name = "Manrope-ExtraBold"
        }
        let base = UIFont(name: name, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }
}

func gpLabel(_ text: String?, font: UIFont, color: UIColor, lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = lines
    label.adjustsFontForContentSizeCategory = true
    return label
}
