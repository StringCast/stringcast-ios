import Foundation

/// CLDR cardinal plural category selection for integer counts.
///
/// Covers the common languages; unknown languages use the English-style `one`/`other` rule.
/// Callers should fall back to `other` when the selected category is missing from a plural map.
public enum PluralRules {
    public enum Category: String, CaseIterable {
        case zero, one, two, few, many, other
    }

    private static let noPlural: Set<String> = [
        "ja", "zh", "ko", "th", "vi", "id", "ms", "lo", "my", "km", "yue", "jv", "su", "bo", "dz", "ig", "yo", "sg", "to",
    ]
    /// `one` for 0 and 1 (i = 0,1).
    private static let zeroOneIsOne: Set<String> = ["hi", "bn", "fa", "gu", "kn", "mr", "zu", "am", "as"]
    /// one: i%10=1 & i%100≠11; few: i%10=2..4 & i%100∉12..14; many: rest (integers).
    private static let eastSlavic: Set<String> = ["ru", "uk", "be"]
    /// one: i%10=1 & i%100≠11; few: i%10=2..4 & i%100∉12..14; other.
    private static let southSlavic: Set<String> = ["hr", "sr", "bs", "sh"]
    /// one: n=1 (and v=0); many: i≠0 & i%1_000_000=0; other.
    private static let romanceMillion: Set<String> = ["es", "it", "ca"]

    /// Language subtag of a BCP-47 tag (`pt-BR` → `pt`).
    static func languageSubtag(_ tag: String) -> String {
        let n = LanguageResolver.normalize(tag)
        return n.split(separator: "-").first.map(String.init) ?? n
    }

    public static func category(for count: Int, language: String) -> Category {
        let lang = languageSubtag(language)
        let normalized = LanguageResolver.normalize(language)
        let n = count.magnitude // UInt, avoids overflow on Int.min
        let mod10 = n % 10
        let mod100 = n % 100

        if noPlural.contains(lang) { return .other }

        switch lang {
        case "fr":
            if n <= 1 { return .one }
            if n % 1_000_000 == 0 { return .many }
            return .other
        case "pt":
            if normalized == "pt-pt" {
                if n == 1 { return .one }
            } else if n <= 1 {
                return .one
            }
            if n != 0 && n % 1_000_000 == 0 { return .many }
            return .other
        case _ where romanceMillion.contains(lang):
            if n == 1 { return .one }
            if n != 0 && n % 1_000_000 == 0 { return .many }
            return .other
        case _ where zeroOneIsOne.contains(lang):
            return n <= 1 ? .one : .other
        case _ where eastSlavic.contains(lang):
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case _ where southSlavic.contains(lang):
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .other
        case "pl":
            if n == 1 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "cs", "sk":
            if n == 1 { return .one }
            if (2...4).contains(n) { return .few }
            return .other
        case "ar":
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (3...10).contains(mod100) { return .few }
            if (11...99).contains(mod100) { return .many }
            return .other
        case "he", "iw":
            if n == 1 { return .one }
            if n == 2 { return .two }
            return .other
        case "ro", "mo":
            if n == 1 { return .one }
            if n == 0 || (2...19).contains(mod100) { return .few }
            return .other
        case "lt":
            if mod10 == 1 && !(11...19).contains(mod100) { return .one }
            if (2...9).contains(mod10) && !(11...19).contains(mod100) { return .few }
            return .other
        case "lv":
            if mod10 == 0 || (11...19).contains(mod100) { return .zero }
            if mod10 == 1 && mod100 != 11 { return .one }
            return .other
        case "sl":
            if mod100 == 1 { return .one }
            if mod100 == 2 { return .two }
            if (3...4).contains(mod100) { return .few }
            return .other
        case "ga":
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (3...6).contains(n) { return .few }
            if (7...10).contains(n) { return .many }
            return .other
        case "cy":
            switch n {
            case 0: return .zero
            case 1: return .one
            case 2: return .two
            case 3: return .few
            case 6: return .many
            default: return .other
            }
        case "is":
            return (mod10 == 1 && mod100 != 11) ? .one : .other
        case "mk":
            return (mod10 == 1 && mod100 != 11) ? .one : .other
        default:
            // en, de, nl, sv, da, nb, nn, no, fi, et, el, hu, tr, bg, eu, gl, ur, sw, af, sq, ...
            return n == 1 ? .one : .other
        }
    }

    /// Picks the form for `count`, falling back to `other` (then `one`, then any form).
    public static func select(_ forms: [String: String], count: Int, language: String) -> String? {
        let cat = category(for: count, language: language).rawValue
        // CLDR allows explicit "zero" forms in maps even when the language has no zero category
        // (mirrors stringsdict behaviour where `zero` is honoured for 0).
        if count == 0, let zero = forms["zero"] { return zero }
        return forms[cat] ?? forms["other"] ?? forms["one"] ?? forms.values.first
    }
}
