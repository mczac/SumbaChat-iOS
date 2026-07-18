//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Shared Xcode-like highlighting for Debug → Compression / Caching rules screens.
enum DebugAlgoCodeDocument {

    struct Colors {
        let background: UIColor
        let plain: UIColor
        let comment: UIColor
        let keyword: UIColor
        let typeName: UIColor
        let number: UIColor
        let attribute: UIColor
    }

    static func colors(for traits: UITraitCollection) -> Colors {
        let dark = traits.userInterfaceStyle == .dark
        return Colors(
            background: dark
                ? UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1),
            plain: dark
                ? UIColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1)
                : UIColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1),
            comment: dark
                ? UIColor(red: 0.42, green: 0.55, blue: 0.38, alpha: 1)
                : UIColor(red: 0.35, green: 0.50, blue: 0.30, alpha: 1),
            keyword: dark
                ? UIColor(red: 0.91, green: 0.55, blue: 0.75, alpha: 1)
                : UIColor(red: 0.72, green: 0.18, blue: 0.55, alpha: 1),
            typeName: dark
                ? UIColor(red: 0.45, green: 0.78, blue: 0.85, alpha: 1)
                : UIColor(red: 0.20, green: 0.45, blue: 0.65, alpha: 1),
            number: dark
                ? UIColor(red: 0.78, green: 0.72, blue: 0.45, alpha: 1)
                : UIColor(red: 0.45, green: 0.35, blue: 0.10, alpha: 1),
            attribute: dark
                ? UIColor(red: 0.75, green: 0.70, blue: 0.45, alpha: 1)
                : UIColor(red: 0.55, green: 0.45, blue: 0.15, alpha: 1)
        )
    }

    static func highlighted(_ source: String, colors: Colors, extraTypes: [String] = []) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: colors.plain
            ]
        )
        let full = NSRange(location: 0, length: result.length)
        let ns = source as NSString

        apply(#"//[^\n]*"#, in: ns, fullRange: full, to: result, color: colors.comment)

        let keywords = [
            "enum", "case", "func", "let", "var", "for", "in", "if", "else",
            "return", "true", "false", "nil", "self", "guard", "while", "struct"
        ]
        for word in keywords {
            apply("\\b\(word)\\b", in: ns, fullRange: full, to: result, color: colors.keyword)
        }

        var types = [
            "Mode", "Level", "Int64", "Double", "Bool", "URL", "Date",
            "AVAssetWriter", "AVAssetExportSession", "ImageIO", "UIImage",
            "MemoryGate", "UploadGate", "SDImageCache", "URLCache",
            "SumbaMedia", "PROPFIND", "LRU", "FIFO"
        ]
        types.append(contentsOf: extraTypes)
        for word in Set(types) {
            apply("\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                  in: ns, fullRange: full, to: result, color: colors.typeName)
        }

        apply(#"\.[a-zA-Z_][a-zA-Z0-9_]*"#, in: ns, fullRange: full, to: result, color: colors.attribute)
        apply(#"\b\d+(\.\d+)?\b"#, in: ns, fullRange: full, to: result, color: colors.number)
        // Comments win over keywords inside // lines
        apply(#"//[^\n]*"#, in: ns, fullRange: full, to: result, color: colors.comment)

        return result
    }

    private static func apply(_ pattern: String,
                              in ns: NSString,
                              fullRange: NSRange,
                              to result: NSMutableAttributedString,
                              color: UIColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: ns as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
