import Foundation

/// A color as a theme file writes it, each component from 0 to 1.
public struct RGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A CSS hex color, `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, its digits in either case; nil for anything else,
    /// which VS Code does not draw either.
    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        var digits: [Int] = []
        for character in text.dropFirst() {
            guard character.isASCII, let digit = character.hexDigitValue else { return nil }
            digits.append(digit)
        }
        let components: [Int]
        switch digits.count {
        case 3, 4: components = digits.map { $0 * 17 }
        case 6, 8: components = stride(from: 0, to: digits.count, by: 2).map { digits[$0] * 16 + digits[$0 + 1] }
        default: return nil
        }
        red = Double(components[0]) / 255
        green = Double(components[1]) / 255
        blue = Double(components[2]) / 255
        alpha = components.count == 4 ? Double(components[3]) / 255 : 1
    }
}
