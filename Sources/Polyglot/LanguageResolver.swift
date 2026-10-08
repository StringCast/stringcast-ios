import Foundation

/// Language resolution per contract §6.4. Pure and side-effect free.
public enum LanguageResolver {
    /// Lowercased, `_` → `-`, for comparison only.
    public static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Resolve the language to use.
    ///
    /// - Parameters:
    ///   - preferred: device languages in priority order (`Locale.preferredLanguages`).
    ///   - available: project languages as stored (manifest order).
    ///   - baseLanguage: project base language (final fallback).
    ///   - override: `languageOverride`; beats everything. Matched against `available` with the
    ///     same rules; if nothing matches, the override is returned as given (normalised `_`→`-`),
    ///     and lookups will then fall through to the base bundle.
    /// - Returns: a code spelled exactly as in `available` when matched.
    public static func resolve(preferred: [String], available: [String], baseLanguage: String, override: String? = nil) -> String {
        if let override = override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            if let hit = match(override, in: available) { return hit }
            return override.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        }
        for tag in preferred {
            if let hit = match(tag, in: available) { return hit }
        }
        return baseLanguage
    }

    /// Match one preferred tag against the project's languages:
    /// exact → language+script → language only → any project language with the same language subtag.
    public static func match(_ tag: String, in available: [String]) -> String? {
        let wanted = normalize(tag)
        guard !wanted.isEmpty else { return nil }
        let normalizedAvailable = available.map { ($0, normalize($0)) }
        func find(_ n: String) -> String? { normalizedAvailable.first { $0.1 == n }?.0 }

        // 1. exact
        if let hit = find(wanted) { return hit }

        let parts = wanted.split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }

        // 2. same language with script (zh-Hans-CN → zh-Hans)
        if parts.count > 1, parts[1].count == 4, parts[1].allSatisfy({ $0.isLetter }) {
            if let hit = find(language + "-" + parts[1]) { return hit }
        }

        // 3. language only
        if let hit = find(language) { return hit }

        // 4. any project language with the same language subtag (first in project order)
        if let hit = normalizedAvailable.first(where: { $0.1.hasPrefix(language + "-") })?.0 { return hit }

        return nil
    }
}
