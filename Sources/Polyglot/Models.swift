import Foundation

/// A single translated value (contract §2).
public enum TranslationValue: Equatable {
    case string(String)
    /// Plural map keyed by CLDR category (`zero`, `one`, `two`, `few`, `many`, `other`).
    case plural([String: String])
    case array([String])

    static let pluralCategories: Set<String> = ["zero", "one", "two", "few", "many", "other"]

    /// Best plain-string representation (`other` for plurals). Arrays have none.
    var plainString: String? {
        switch self {
        case .string(let s): return s
        case .plural(let map): return map["other"] ?? map["one"] ?? map.values.first
        case .array: return nil
        }
    }
}

extension TranslationValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([String].self) {
            self = .array(a)
        } else if let m = try? c.decode([String: String].self) {
            let filtered = m.filter { TranslationValue.pluralCategories.contains($0.key) }
            guard !filtered.isEmpty else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Plural map has no CLDR categories")
            }
            self = .plural(filtered)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported value type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .plural(let m): try c.encode(m)
        case .array(let a): try c.encode(a)
        }
    }
}

/// A release bundle for one language (contract §3).
public struct TranslationBundle: Equatable {
    public var projectId: String
    public var version: Int
    public var language: String
    public var publishedAt: String?
    public var strings: [String: TranslationValue]

    public init(projectId: String, version: Int, language: String, publishedAt: String? = nil, strings: [String: TranslationValue]) {
        self.projectId = projectId
        self.version = version
        self.language = language
        self.publishedAt = publishedAt
        self.strings = strings
    }

    /// Direct lookup, plus iOS-style array element keys (`planets.1` → `planets[1]`).
    func value(for key: String) -> TranslationValue? {
        if let v = strings[key] { return v }
        if let dot = key.lastIndex(of: "."),
           let index = Int(key[key.index(after: dot)...]), index >= 0,
           case .array(let items)? = strings[String(key[..<dot])], index < items.count {
            return .string(items[index])
        }
        return nil
    }

    func contains(_ key: String) -> Bool { value(for: key) != nil }
}

extension TranslationBundle: Codable {
    private enum CodingKeys: String, CodingKey { case projectId, version, language, publishedAt, strings }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = (try? c.decode(String.self, forKey: .projectId)) ?? ""
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        language = try c.decode(String.self, forKey: .language)
        publishedAt = try? c.decode(String.self, forKey: .publishedAt)
        // Lenient: a single malformed value must not invalidate the whole bundle.
        var result: [String: TranslationValue] = [:]
        if let sc = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .strings) {
            for k in sc.allKeys {
                if let v = try? sc.decode(TranslationValue.self, forKey: k) {
                    result[k.stringValue] = v
                }
            }
        }
        strings = result
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(version, forKey: .version)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try c.encode(strings, forKey: .strings)
    }
}

/// `GET /v1/sdk/{projectId}/manifest` (contract §4.2).
public struct Manifest: Codable, Equatable {
    public struct Language: Codable, Equatable {
        public var code: String
        public var url: String
        public var hash: String?
        public var keyCount: Int?

        public init(code: String, url: String, hash: String? = nil, keyCount: Int? = nil) {
            self.code = code
            self.url = url
            self.hash = hash
            self.keyCount = keyCount
        }
    }

    public var projectId: String
    public var version: Int
    public var publishedAt: String?
    public var baseLanguage: String
    public var languages: [Language]

    public init(projectId: String, version: Int, publishedAt: String? = nil, baseLanguage: String, languages: [Language]) {
        self.projectId = projectId
        self.version = version
        self.publishedAt = publishedAt
        self.baseLanguage = baseLanguage
        self.languages = languages
    }

    func entry(for code: String) -> Language? {
        let n = LanguageResolver.normalize(code)
        return languages.first { LanguageResolver.normalize($0.code) == n }
    }
}

/// Manifest plus HTTP/cache metadata persisted alongside it.
struct CachedManifest: Codable, Equatable {
    var manifest: Manifest
    var etag: String?
    var lastCheck: Date?
}
