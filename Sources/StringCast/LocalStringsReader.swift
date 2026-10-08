import Foundation

/// Reads the app's base-language `Localizable.strings` / `.stringsdict` / `.xcstrings`.
enum LocalStringsReader {
    struct Result {
        var language: String
        var entries: [String: TranslationValue]
    }

    /// Reads from `bundle`'s development-region localization (falls back to unlocalized resources).
    static func read(bundle: Bundle, fallbackLanguage: String?) -> Result {
        var dev = bundle.developmentLocalization ?? fallbackLanguage ?? "en"
        if dev == "Base" { dev = fallbackLanguage ?? "en" }
        var entries: [String: TranslationValue] = [:]

        if let url = locate(bundle, "Localizable", "xcstrings", dev) ?? bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
           let data = try? Data(contentsOf: url) {
            let parsed = parseXCStrings(data, language: dev)
            entries.merge(parsed.entries) { _, new in new }
        }
        if let url = locate(bundle, "Localizable", "strings", dev),
           let dict = NSDictionary(contentsOf: url) as? [String: Any] {
            entries.merge(parseStrings(dict)) { _, new in new }
        }
        if let url = locate(bundle, "Localizable", "stringsdict", dev),
           let dict = NSDictionary(contentsOf: url) as? [String: Any] {
            entries.merge(parseStringsDict(dict)) { _, new in new }
        }
        return Result(language: dev, entries: entries)
    }

    private static func locate(_ bundle: Bundle, _ name: String, _ ext: String, _ language: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: nil, localization: language)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: nil, localization: "Base")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    /// `.strings` (text or compiled binary plist, both readable as a property list).
    static func parseStrings(_ dict: [String: Any]) -> [String: TranslationValue] {
        var out: [String: TranslationValue] = [:]
        for (k, v) in dict { if let s = v as? String { out[k] = .string(s) } }
        return out
    }

    static func parseStrings(text: String) -> [String: TranslationValue] {
        guard let dict = text.propertyListFromStringsFileFormat() as [String: String]? else { return [:] }
        return dict.mapValues { .string($0) }
    }

    /// `.stringsdict`: expands `NSStringLocalizedFormatKey` with the first plural variable's forms.
    /// Other variables are substituted with their `other` form.
    static func parseStringsDict(_ dict: [String: Any]) -> [String: TranslationValue] {
        var out: [String: TranslationValue] = [:]
        for (key, raw) in dict {
            guard let entry = raw as? [String: Any], let format = entry["NSStringLocalizedFormatKey"] as? String else { continue }
            let variables = variableNames(in: format)
            var forms: [String: String] = [:]
            var others: [(token: String, other: String)] = []
            var primary: (token: String, forms: [String: String])?
            for (token, name) in variables {
                guard let spec = entry[name] as? [String: Any] else { continue }
                var varForms: [String: String] = [:]
                for cat in TranslationValue.pluralCategories { if let s = spec[cat] as? String { varForms[cat] = s } }
                if primary == nil, !varForms.isEmpty { primary = (token, varForms) }
                else if let o = varForms["other"] { others.append((token, o)) }
            }
            guard let p = primary else { continue }
            for (cat, form) in p.forms {
                var s = format.replacingOccurrences(of: p.token, with: form)
                for o in others { s = s.replacingOccurrences(of: o.token, with: o.other) }
                forms[cat] = s
            }
            if forms["other"] == nil { forms["other"] = forms["many"] ?? forms["one"] ?? forms.values.first }
            out[key] = .plural(forms)
        }
        return out
    }

    /// `%#@name@` / `%1$#@name@` tokens → (token, name).
    static func variableNames(in format: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:\\d+\\$)?#@([^@]+)@") else { return [] }
        let ns = format as NSString
        return regex.matches(in: format, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range), ns.substring(with: $0.range(at: 1)))
        }
    }

    /// String Catalog JSON. Keys without a value in `language` use the key itself (source = key).
    static func parseXCStrings(_ data: Data, language: String) -> (sourceLanguage: String?, entries: [String: TranslationValue]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { return (nil, [:]) }
        let source = root["sourceLanguage"] as? String
        let lang = source ?? language
        var out: [String: TranslationValue] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            if let should = entry["shouldTranslate"] as? Bool, should == false { continue }
            let loc = (entry["localizations"] as? [String: Any])?[lang] as? [String: Any]
            if let unit = loc?["stringUnit"] as? [String: Any], let v = unit["value"] as? String {
                out[key] = .string(v)
            } else if let plural = (loc?["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                var forms: [String: String] = [:]
                for (cat, f) in plural {
                    if TranslationValue.pluralCategories.contains(cat),
                       let v = ((f as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                        forms[cat] = v
                    }
                }
                if !forms.isEmpty { out[key] = .plural(forms) }
            } else if loc == nil, !key.isEmpty {
                out[key] = .string(key)
            }
        }
        return (source, out)
    }
}
