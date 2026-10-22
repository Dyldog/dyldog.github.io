import Foundation

enum Slug {
    /// Lowercase ASCII letters and digits joined by `separator`; apostrophes are dropped so
    /// "Sexy’s Back" becomes "sexys-back".
    static func make(_ text: String, separator: Character = "-", keeping kept: Set<Character> = []) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        var pendingSeparator = false
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber || kept.contains(character)) {
                if pendingSeparator && !result.isEmpty { result.append(separator) }
                result.append(character)
                pendingSeparator = false
            } else if character == "'" || character == "’" {
                continue
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    /// A safe file name stem that keeps the original's case, e.g. "IMG_5015".
    static func fileStem(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber || "_-.".contains(character)) {
                result.append(character)
            } else if result.last != "-" {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}
