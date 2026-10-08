import Foundation

/// Persistence for the manifest and downloaded bundles. Injected so the engine is testable.
protocol BundleStore: AnyObject {
    func loadManifest() -> CachedManifest?
    func saveManifest(_ manifest: CachedManifest) throws
    func loadBundle(language: String) -> TranslationBundle?
    /// `data` is the raw downloaded JSON (stored verbatim); `bundle` is its decoded form.
    func saveBundle(_ bundle: TranslationBundle, data: Data) throws
}

/// In-memory store (tests, or apps that do not want disk caching).
final class InMemoryBundleStore: BundleStore {
    private let lock = NSLock()
    private var manifest: CachedManifest?
    private var bundles: [String: TranslationBundle] = [:]

    init(manifest: CachedManifest? = nil, bundles: [TranslationBundle] = []) {
        self.manifest = manifest
        for b in bundles { self.bundles[LanguageResolver.normalize(b.language)] = b }
    }

    func loadManifest() -> CachedManifest? {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    func saveManifest(_ manifest: CachedManifest) throws {
        lock.lock(); defer { lock.unlock() }
        self.manifest = manifest
    }

    func loadBundle(language: String) -> TranslationBundle? {
        lock.lock(); defer { lock.unlock() }
        return bundles[LanguageResolver.normalize(language)]
    }

    func saveBundle(_ bundle: TranslationBundle, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        bundles[LanguageResolver.normalize(bundle.language)] = bundle
    }
}

/// `Application Support/Polyglot/<projectId>/{manifest.json, bundles/<lang>.json}` with atomic writes.
final class DiskBundleStore: BundleStore {
    let directory: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    init(projectId: String, rootDirectory: URL? = nil) {
        let root = rootDirectory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safeId = projectId.replacingOccurrences(of: "/", with: "_")
        directory = root.appendingPathComponent("Polyglot", isDirectory: true).appendingPathComponent(safeId, isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var bundlesDir: URL { directory.appendingPathComponent("bundles", isDirectory: true) }

    private func bundleURL(_ language: String) -> URL {
        let safe = LanguageResolver.normalize(language).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return bundlesDir.appendingPathComponent("\(safe).json")
    }

    private func ensureDirectories() throws {
        try fm.createDirectory(at: bundlesDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true // re-downloadable content
        var dir = directory
        try? dir.setResourceValues(values)
    }

    func loadManifest() -> CachedManifest? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CachedManifest.self, from: data)
    }

    func saveManifest(_ manifest: CachedManifest) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func loadBundle(language: String) -> TranslationBundle? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: bundleURL(language)) else { return nil }
        return try? JSONDecoder().decode(TranslationBundle.self, from: data)
    }

    func saveBundle(_ bundle: TranslationBundle, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        try data.write(to: bundleURL(bundle.language), options: .atomic)
    }
}
