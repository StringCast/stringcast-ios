import Foundation

/// Looks up the app's own compiled string (`Bundle.main`'s Localizable table). Returns nil when absent.
typealias AppStringsProvider = (_ key: String) -> String?

/// Core runtime. All public entry points are thread-safe; lookups take one short lock.
final class StringCastEngine {
    struct Snapshot {
        var cached: CachedManifest?
        var resolvedLanguage: String
        var active: TranslationBundle?
        var base: TranslationBundle?
    }

    let config: StringCastConfig
    private let store: BundleStore
    private var api: APIClient
    private let appInfo: CheckInHeaders.AppInfo
    private let appStrings: AppStringsProvider
    private let preferredLanguages: () -> [String]
    private let now: () -> Date
    /// App bundle whose tables (and those of every bundle inside it) are uploaded in draft mode (`Bundle.main` in apps).
    let localBundle: Bundle
    private let defaults: UserDefaults
    private var autoUploadTask: Task<Void, Never>?
    /// Called (on an arbitrary thread) after translations visible to lookups changed.
    var onChange: ((Snapshot) -> Void)?

    private let lock = NSLock()
    private var state: Snapshot
    private var languageOverride: String?
    private var refreshTask: Task<Void, Never>?
    private(set) var reporter: MissingKeyReporter?

    init(
        config: StringCastConfig,
        store: BundleStore,
        transport: HTTPTransport,
        appStrings: @escaping AppStringsProvider,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        now: @escaping () -> Date = Date.init,
        appInfo: CheckInHeaders.AppInfo = .from(.main),
        localBundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.localBundle = localBundle
        self.defaults = defaults
        self.config = config
        self.store = store
        self.api = APIClient(baseURL: config.baseURL, projectId: config.projectId, sdkKey: config.sdkKey, transport: transport)
        self.appStrings = appStrings
        self.preferredLanguages = preferredLanguages
        self.now = now
        self.languageOverride = config.languageOverride
        self.appInfo = appInfo
        self.state = Snapshot(cached: nil, resolvedLanguage: config.languageOverride ?? preferredLanguages().first ?? "en")
        let fallbackHeaders = CheckInHeaders.build(app: appInfo, language: nil)
        self.api.checkInHeaders = { [weak self] in self?.checkInHeaders() ?? fallbackHeaders }
        loadFromCache()
        if config.draftMode {
            reporter = MissingKeyReporter(api: api, debounce: config.missingKeyDebounce, excludedKeys: config.excludedKeys) { [weak self] in
                self?.reporterContext()
            }
        }
    }

    // MARK: - State

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    var currentLanguage: String { snapshot.resolvedLanguage }

    private func resolve(_ manifest: Manifest?, override: String?) -> String {
        guard let manifest = manifest else {
            return override ?? preferredLanguages().first.map { $0.replacingOccurrences(of: "_", with: "-") } ?? "en"
        }
        return LanguageResolver.resolve(
            preferred: preferredLanguages(),
            available: manifest.languages.map(\.code),
            baseLanguage: manifest.baseLanguage,
            override: override
        )
    }

    /// Synchronous: reads cached manifest + bundles so the first screen is localized.
    private func loadFromCache() {
        let cached = store.loadManifest()
        lock.lock()
        let override = languageOverride
        lock.unlock()
        let resolved = resolve(cached?.manifest, override: override)
        let active = store.loadBundle(language: resolved)
        let base = cached.flatMap { store.loadBundle(language: $0.manifest.baseLanguage) }
        lock.lock()
        state = Snapshot(cached: cached, resolvedLanguage: resolved, active: active, base: base)
        lock.unlock()
        if let c = cached {
            Log.debug("loaded cache v\(c.manifest.version), language \(resolved)")
        }
    }

    /// Re-reads bundles from the store for the current manifest/override. Returns true if visible content changed.
    @discardableResult
    private func reloadState(manifest: CachedManifest?) -> Bool {
        lock.lock()
        let override = languageOverride
        lock.unlock()
        let resolved = resolve(manifest?.manifest, override: override)
        let active = store.loadBundle(language: resolved)
        let base = manifest.flatMap { store.loadBundle(language: $0.manifest.baseLanguage) }
        lock.lock()
        let old = state
        state = Snapshot(cached: manifest, resolvedLanguage: resolved, active: active, base: base)
        let new = state
        lock.unlock()
        let changed = old.resolvedLanguage != new.resolvedLanguage
            || old.cached?.manifest.version != new.cached?.manifest.version
            || old.active != new.active
            || old.base != new.base
        if changed { onChange?(new) }
        return changed
    }

    /// Check-in headers for the next API request. The language is resolved now (§6.4, honouring
    /// `languageOverride` / `setLanguage`); before any manifest is known only an override counts.
    func checkInHeaders() -> [String: String] {
        let (manifest, override) = lock.locked { (state.cached?.manifest, languageOverride) }
        let language: String?
        if manifest != nil {
            language = resolve(manifest, override: override)
        } else {
            language = override.flatMap { $0.isEmpty ? nil : $0 }
        }
        return CheckInHeaders.build(app: appInfo, language: language)
    }

    func setLanguage(_ code: String?) {
        lock.lock()
        languageOverride = code
        let cached = state.cached
        lock.unlock()
        reloadState(manifest: cached)
        Task { await self.ensureBundles() }
    }

    // MARK: - Lookup

    private func otaBundles() -> [TranslationBundle] {
        let s = snapshot
        var result: [TranslationBundle] = []
        if let a = s.active { result.append(a) }
        if let b = s.base, LanguageResolver.normalize(b.language) != LanguageResolver.normalize(s.active?.language ?? "") {
            result.append(b)
        }
        return result
    }

    private static func locale(for language: String) -> Locale {
        Locale(identifier: language.replacingOccurrences(of: "-", with: "_"))
    }

    /// Lookup order (§6.5): resolved bundle → base bundle → app's compiled string → `defaultValue` → key.
    func string(_ key: String, defaultValue: String?, args: [CVarArg]) -> String {
        let bundles = otaBundles()
        for bundle in bundles {
            if let template = bundle.value(for: key)?.plainString,
               let s = PlaceholderFormatter.format(template, args: args, locale: Self.locale(for: bundle.language)) {
                noteUsage(key, base: snapshot.base, local: { self.appStrings(key).map(TranslationValue.string) ?? defaultValue.map(TranslationValue.string) })
                return s
            }
        }
        let compiled = appStrings(key)
        noteUsage(key, base: snapshot.base, local: { (compiled ?? defaultValue).map(TranslationValue.string) })
        if let compiled = compiled, let s = Self.formatCompiled(compiled, args: args) { return s }
        if let d = defaultValue, let s = PlaceholderFormatter.format(d, args: args, locale: .current) { return s }
        return key
    }

    func pluralString(_ key: String, count: Int, defaultValue: String?, args: [CVarArg]) -> String {
        let args: [CVarArg] = args.isEmpty ? [count] : args
        for bundle in otaBundles() {
            guard let value = bundle.value(for: key) else { continue }
            let template: String?
            switch value {
            case .plural(let forms): template = PluralRules.select(forms, count: count, language: bundle.language)
            case .string(let s): template = s
            case .array: template = nil
            }
            if let t = template, let s = PlaceholderFormatter.format(t, args: args, locale: Self.locale(for: bundle.language)) {
                return s
            }
        }
        let compiled = appStrings(key)
        noteUsage(key, base: snapshot.base, local: {
            // A compiled stringsdict format (`%#@var@`) is not a useful base value; prefer the default.
            if let d = defaultValue { return .string(d) }
            if let c = compiled, !c.contains("%#@") { return .string(c) }
            return nil
        })
        if let compiled = compiled, let s = Self.formatCompiled(compiled, args: args) { return s }
        if let d = defaultValue, let s = PlaceholderFormatter.format(d, args: args, locale: .current) { return s }
        return key
    }

    /// Array value (`planets` → `["Mercury", …]`), resolved then base bundle.
    func stringArray(_ key: String) -> [String]? {
        for bundle in otaBundles() {
            if case .array(let items)? = bundle.strings[key] { return items.map(PlaceholderFormatter.normalize) }
        }
        return nil
    }

    /// Used by the bundle interception (any app bundle, any table): OTA string for `key`, else nil
    /// (plural values return nil so the compiled `.stringsdict` keeps working with `String(format:)`).
    /// In draft mode a key absent from the base bundle is reported with `original()`, the compiled value
    /// of the bundle/table that was asked.
    func bundleLookup(_ key: String, original: () -> String?) -> String? {
        for bundle in otaBundles() {
            guard let value = bundle.value(for: key) else { continue }
            if case .plural = value { break }
            if let s = value.plainString { return PlaceholderFormatter.normalize(s) }
        }
        if reporter != nil, !(snapshot.base?.contains(key) ?? false) {
            let local = original()
            if let local = local, !local.contains("%#@") { reporter?.record(key, value: .string(local)) }
        }
        return nil
    }

    /// App's own string formatted without normalisation (keeps `.stringsdict` plural behaviour).
    static func formatCompiled(_ template: String, args: [CVarArg]) -> String? {
        if args.isEmpty { return template }
        guard PlaceholderFormatter.validate(template, args: args) else { return nil }
        return String(format: template, locale: Locale.current, arguments: args)
    }

    private func noteUsage(_ key: String, base: TranslationBundle?, local: () -> TranslationValue?) {
        guard let reporter = reporter, !(base?.contains(key) ?? false), !reporter.alreadySeen(key) else { return }
        if let value = local() { reporter.record(key, value: value) }
    }

    private func reporterContext() -> MissingKeyReporter.Context? {
        let s = snapshot
        guard let manifest = s.cached?.manifest else { return nil }
        // When the project has published bundles we must have the base bundle to judge "missing".
        if manifest.version > 0, manifest.entry(for: manifest.baseLanguage) != nil, s.base == nil { return nil }
        let base = s.base
        return MissingKeyReporter.Context(language: manifest.baseLanguage) { key in base?.contains(key) ?? false }
    }

    // MARK: - Refresh

    func refresh(force: Bool) async {
        let (task, joined): (Task<Void, Never>, Bool) = lock.locked {
            if let running = refreshTask { return (running, true) }
            let t = Task { await self.performRefresh(force: force) }
            refreshTask = t
            return (t, false)
        }
        await task.value
        if joined {
            if force { await refresh(force: true) }
            return
        }
        lock.locked { refreshTask = nil }
    }

    private func performRefresh(force: Bool) async {
        let cached = snapshot.cached
        if !force, let last = cached?.lastCheck, now().timeIntervalSince(last) < config.refreshInterval, last <= now() {
            Log.debug("manifest checked \(Int(now().timeIntervalSince(last)))s ago; skipping")
            await ensureBundles()
            return
        }
        do {
            let manifest: Manifest
            let etag: String?
            switch try await api.fetchManifest(etag: cached == nil ? nil : cached?.etag) {
            case .notModified:
                guard let c = cached else { return }
                manifest = c.manifest
                etag = c.etag
                Log.debug("manifest not modified (v\(manifest.version))")
            case .updated(let m, let e):
                manifest = m
                etag = e
                Log.debug("manifest v\(m.version) (\(m.languages.map(\.code).joined(separator: ",")))")
            }
            let override = lock.locked { languageOverride }
            let resolved = resolve(manifest, override: override)
            try await download(languages: [resolved, manifest.baseLanguage], manifest: manifest)
            // Bundles first, manifest last: a crash in between leaves a consistent (older) manifest.
            let newCached = CachedManifest(manifest: manifest, etag: etag, lastCheck: now())
            try store.saveManifest(newCached)
            reloadState(manifest: newCached)
        } catch {
            Log.debug("refresh failed: \(error)")
        }
    }

    /// Downloads bundles for `languages` that are missing or older than the manifest version.
    private func download(languages: [String], manifest: Manifest) async throws {
        var seen = Set<String>()
        for code in languages {
            guard let entry = manifest.entry(for: code), seen.insert(LanguageResolver.normalize(entry.code)).inserted else { continue }
            if let existing = store.loadBundle(language: entry.code), existing.version == manifest.version { continue }
            let (bundle, data) = try await api.fetchBundle(entry, expectedVersion: manifest.version)
            try store.saveBundle(bundle, data: data)
            Log.debug("downloaded \(entry.code) v\(bundle.version) (\(bundle.strings.count) keys)")
        }
    }

    /// Lazily fetches the resolved language bundle (e.g. after `setLanguage`) without a manifest check.
    func ensureBundles() async {
        let s = snapshot
        guard let cached = s.cached else { return }
        do {
            try await download(languages: [s.resolvedLanguage, cached.manifest.baseLanguage], manifest: cached.manifest)
            reloadState(manifest: cached)
        } catch {
            Log.debug("bundle download failed: \(error)")
        }
    }

    // MARK: - Upload

    /// Posts `entries` for one language in batches of ≤ 500 (`excludedKeys` removed). Throws on the first failed batch.
    func upload(_ entries: [String: TranslationValue], language: String) async throws -> UploadResult {
        var total = UploadResult(created: 0, filled: 0, ignored: 0)
        let keys = entries.keys.filter { !config.excludedKeys.contains($0) }.sorted()
        var index = 0
        while index < keys.count {
            let chunk = keys[index..<min(index + MissingKeyReporter.maxBatch, keys.count)]
            let payload = MissingKeyPayload(language: language, keys: chunk.map { .init(key: $0, value: entries[$0]!) })
            total = total + (try await api.reportMissing(payload))
            index += MissingKeyReporter.maxBatch
        }
        return total
    }

    /// Reads every table of `root` and of every bundle inside it (`AppBundles.discover`): base values plus
    /// existing translations for every project language, `excludedKeys` removed. Without a known manifest
    /// only the development-region values are collected.
    func collectLocalStrings(root: Bundle) -> LocalStringsReader.Collection {
        let bundles = AppBundles.discover(root: root)
        var collection: LocalStringsReader.Collection
        if let manifest = snapshot.cached?.manifest {
            collection = LocalStringsReader.collect(bundles: bundles, baseLanguage: manifest.baseLanguage,
                                                    languages: manifest.languages.map(\.code))
        } else {
            let dev = root.developmentLocalization.flatMap { $0 == "Base" ? nil : $0 } ?? "en"
            collection = LocalStringsReader.collect(bundles: bundles, baseLanguage: dev, languages: [])
        }
        if !config.excludedKeys.isEmpty {
            for i in collection.units.indices {
                collection.units[i].entries = collection.units[i].entries.filter { !config.excludedKeys.contains($0.key) }
            }
        }
        return collection
    }

    /// Uploads a collection, one language per request. Throws on the first failed batch.
    func upload(_ collection: LocalStringsReader.Collection) async throws -> UploadResult {
        var total = UploadResult(created: 0, filled: 0, ignored: 0)
        for unit in collection.units where !unit.entries.isEmpty {
            let r = try await upload(unit.entries, language: unit.language)
            Log.debug("uploaded \(unit.entries.count) \(unit.language) strings from \(Self.describe(unit.origins)) (created \(r.created), filled \(r.filled), ignored \(r.ignored))")
            total = total + r
        }
        return total
    }

    /// Uploads the base values and existing translations of `bundle` and every bundle inside it.
    func uploadLocalStrings(bundle: Bundle) async throws -> UploadResult {
        try await upload(collectLocalStrings(root: bundle))
    }

    static func describe(_ origins: [LocalStringsReader.TableOrigin]) -> String {
        origins.isEmpty ? "nothing" : origins.map { "\($0.bundle)/\($0.table) \($0.count)" }.joined(separator: ", ")
    }

    /// Where the reader looked, for the "nothing found" warning.
    static func emptyCollectionMessage(_ c: LocalStringsReader.Collection, marker: String) -> String {
        let looked = c.scanned.map { "\($0.path) [\($0.tables.isEmpty ? "no tables" : "tables: " + $0.tables.joined(separator: ", "))]" }
        let language = c.units.first?.language ?? "?"
        return "auto-upload found no local strings for base language '\(language)' (build \(marker)); nothing was uploaded "
            + "and it will retry on the next launch. Looked in \(c.scanned.count) bundle(s): \(looked.joined(separator: "; ")). "
            + "Check that your .strings/.stringsdict/.xcstrings files are in the app target's Copy Bundle Resources or in a "
            + "Swift package's resources, and that an .lproj matches the project's base language or the bundle's development region."
    }

    static func uploadSummary(_ c: LocalStringsReader.Collection, result r: UploadResult, marker: String) -> String {
        let bundles = Set(c.units.flatMap { $0.origins.map(\.bundle) })
        let tables = Set(c.units.flatMap { $0.origins.map { "\($0.bundle)/\($0.table)" } })
        let perLanguage = c.units.filter { !$0.entries.isEmpty }.map { "\($0.language) \($0.entries.count)" }.joined(separator: ", ")
        let base = c.units.first.map { describe($0.origins) } ?? "nothing"
        return "uploaded local strings for build \(marker): \(bundles.count) bundle(s), \(tables.count) table(s); keys per language: "
            + "\(perLanguage); base from \(base); created \(r.created), filled \(r.filled), ignored \(r.ignored)"
    }

    /// `CFBundleShortVersionString|CFBundleVersion|sdkVersion` of the uploaded bundle.
    static func buildMarker(for bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short)|\(build)|\(StringCast.sdkVersion)"
    }

    var autoUploadMarkerKey: String { "app.stringcast.\(config.projectId).autoUploadMarker" }

    /// Draft mode: uploads base values + translations once per app build. Needs a manifest (cache or a
    /// successful fetch); otherwise it retries on the next launch. The marker is stored only after every
    /// batch succeeded AND at least one string was found (an empty run logs a warning and retries).
    /// Never throws.
    func autoUploadIfNeeded() async {
        guard config.draftMode, config.autoUploadLocalStrings else { return }
        let task: Task<Void, Never> = lock.locked {
            if let running = autoUploadTask { return running }
            let t = Task { await self.performAutoUpload() }
            autoUploadTask = t
            return t
        }
        await task.value
    }

    private func performAutoUpload() async {
        let marker = Self.buildMarker(for: localBundle)
        if defaults.string(forKey: autoUploadMarkerKey) == marker {
            Log.debug("local strings already uploaded for build \(marker)")
            return
        }
        // `start` runs this after the first refresh, so a manifest is either cached or was just fetched.
        guard snapshot.cached != nil else {
            Log.warn("auto-upload postponed: no project manifest yet (offline, wrong projectId/sdkKey or baseURL?); will retry on the next launch")
            return
        }
        let collection = collectLocalStrings(root: localBundle)
        guard !collection.isEmpty else {
            // Never mark an empty run as done: a misconfigured or not-yet-bundled build must retry.
            Log.warn(Self.emptyCollectionMessage(collection, marker: marker))
            return
        }
        do {
            let r = try await upload(collection)
            defaults.set(marker, forKey: autoUploadMarkerKey)
            Log.notice(Self.uploadSummary(collection, result: r, marker: marker))
        } catch {
            Log.warn("auto-upload of local strings failed (will retry next launch): \(error)")
        }
    }
}
