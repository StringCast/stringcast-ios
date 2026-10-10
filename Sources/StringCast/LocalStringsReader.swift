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

// MARK: - Full upload (base + existing translations)

extension LocalStringsReader {
    /// One `/missing` upload unit: the values of one project language.
    struct LanguageEntries: Equatable {
        /// Project language code (as spelled by the manifest), sent as `language`.
        var language: String
        /// The `.lproj` folder the values came from (nil = unlocalized resources / String Catalog).
        var source: String?
        var entries: [String: TranslationValue]
    }

    /// `*.lproj` folders of `bundle` (name without extension → URL). Read from disk, so it works for any
    /// directory-backed bundle and isn't affected by `Bundle`'s localization caching.
    static func lprojDirectories(in bundle: Bundle) -> [String: URL] {
        let root = bundle.resourceURL ?? bundle.bundleURL
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [String: URL] = [:]
        for url in items where url.pathExtension.lowercased() == "lproj" {
            out[url.deletingPathExtension().lastPathComponent] = url
        }
        return out
    }

    /// Chinese folder names Xcode used before script subtags (`zh_CN.lproj`) and their script equivalents.
    private static let chineseAliases: [String: [String]] = [
        "zh-hans": ["zh-cn", "zh-sg", "zh-hans-cn"],
        "zh-hant": ["zh-tw", "zh-hk", "zh-mo", "zh-hant-tw", "zh-hant-hk"],
        "zh-cn": ["zh-hans"], "zh-sg": ["zh-hans"],
        "zh-tw": ["zh-hant"], "zh-hk": ["zh-hant"], "zh-mo": ["zh-hant"],
    ]

    /// Finds the `.lproj` name for a project language: exact (`es-MX`) → language+script (`zh-Hans-CN` →
    /// `zh-Hans`) → language only (`es-MX` → `es`). Case-insensitive, `_` ≡ `-`. `Base` never matches.
    static func matchLproj(_ language: String, in names: [String]) -> String? {
        let candidates = names.filter { $0.caseInsensitiveCompare("Base") != .orderedSame }
            .map { ($0, LanguageResolver.normalize($0)) }
        func find(_ n: String) -> String? { candidates.first { $0.1 == n }?.0 }
        let wanted = LanguageResolver.normalize(language)
        guard !wanted.isEmpty else { return nil }
        if let hit = find(wanted) { return hit }
        for alias in chineseAliases[wanted] ?? [] { if let hit = find(alias) { return hit } }
        let parts = wanted.split(separator: "-").map(String.init)
        guard let lang = parts.first else { return nil }
        if parts.count > 1, parts[1].count == 4, parts[1].allSatisfy({ $0.isLetter }) {
            let scripted = lang + "-" + parts[1]
            if let hit = find(scripted) { return hit }
            for alias in chineseAliases[scripted] ?? [] { if let hit = find(alias) { return hit } }
        }
        return find(lang)
    }

    /// `Localizable.strings` + `Localizable.stringsdict` of one folder (stringsdict wins on conflicts).
    static func readTable(in directory: URL) -> [String: TranslationValue] {
        var entries: [String: TranslationValue] = [:]
        let strings = directory.appendingPathComponent("Localizable.strings")
        if let dict = NSDictionary(contentsOf: strings) as? [String: Any] {
            entries.merge(parseStrings(dict)) { _, new in new }
        }
        let stringsDict = directory.appendingPathComponent("Localizable.stringsdict")
        if let dict = NSDictionary(contentsOf: stringsDict) as? [String: Any] {
            entries.merge(parseStringsDict(dict)) { _, new in new }
        }
        return entries
    }

    /// Values of one localization in a String Catalog (no implicit "key = value" fallback).
    static func parseXCStrings(_ data: Data, localization: String) -> [String: TranslationValue] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { return [:] }
        var out: [String: TranslationValue] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            if let should = entry["shouldTranslate"] as? Bool, should == false { continue }
            guard let locs = entry["localizations"] as? [String: Any],
                  let name = matchLproj(localization, in: Array(locs.keys)),
                  let loc = locs[name] as? [String: Any] else { continue }
            if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String {
                out[key] = .string(v)
            } else if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                var forms: [String: String] = [:]
                for (cat, f) in plural where TranslationValue.pluralCategories.contains(cat) {
                    if let v = ((f as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { forms[cat] = v }
                }
                if !forms.isEmpty { out[key] = .plural(forms) }
            }
        }
        return out
    }

    /// Everything to upload from `bundle`'s `Localizable` table: the base values (sent as `baseLanguage`)
    /// followed by each other project language that has a matching `.lproj`.
    ///
    /// Base folder: the `.lproj` matching `baseLanguage`, else the development region's, else `Base.lproj`,
    /// else unlocalized resources (each file type falls back to `Base.lproj` / unlocalized like `read`).
    /// A translation folder that resolves to the base folder (e.g. `en-GB` → `en.lproj`) is skipped.
    static func collect(bundle: Bundle, baseLanguage: String, languages: [String]) -> [LanguageEntries] {
        let dirs = lprojDirectories(in: bundle)
        let names = dirs.keys.sorted()
        let root = bundle.resourceURL ?? bundle.bundleURL
        let devRegion = bundle.developmentLocalization.flatMap { $0 == "Base" ? nil : $0 }
        let baseName = matchLproj(baseLanguage, in: names)
            ?? devRegion.flatMap { matchLproj($0, in: names) }
            ?? names.first { $0.caseInsensitiveCompare("Base") == .orderedSame }

        let catalogData = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent == "Localizable.xcstrings" }
            .flatMap { try? Data(contentsOf: $0) }

        // Base values.
        var base: [String: TranslationValue] = [:]
        if let data = catalogData {
            base.merge(parseXCStrings(data, language: baseLanguage).entries) { _, new in new }
        }
        let baseDirs = [baseName.flatMap { dirs[$0] }, names.first { $0.caseInsensitiveCompare("Base") == .orderedSame }.flatMap { dirs[$0] }, root]
            .compactMap { $0 }
        for file in ["Localizable.strings", "Localizable.stringsdict"] {
            guard let dir = baseDirs.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) }) else { continue }
            let url = dir.appendingPathComponent(file)
            guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
            base.merge(file.hasSuffix("dict") ? parseStringsDict(dict) : parseStrings(dict)) { _, new in new }
        }
        var result = [LanguageEntries(language: baseLanguage, source: baseName, entries: base)]

        // Existing translations.
        let baseNormalized = LanguageResolver.normalize(baseLanguage)
        var seen = Set([baseNormalized])
        for language in languages {
            let n = LanguageResolver.normalize(language)
            guard seen.insert(n).inserted else { continue }
            var entries: [String: TranslationValue] = [:]
            var source: String?
            if let data = catalogData {
                entries.merge(parseXCStrings(data, localization: language)) { _, new in new }
            }
            if let name = matchLproj(language, in: names), name != baseName, let dir = dirs[name] {
                source = name
                entries.merge(readTable(in: dir)) { _, new in new }
            }
            entries = entries.filter { !isEmpty($0.value) }
            if !entries.isEmpty { result.append(LanguageEntries(language: language, source: source, entries: entries)) }
        }
        return result
    }

    private static func isEmpty(_ value: TranslationValue) -> Bool {
        switch value {
        case .string(let s): return s.isEmpty
        case .plural(let m): return m.values.allSatisfy { $0.isEmpty }
        case .array(let a): return a.isEmpty
        }
    }
}
