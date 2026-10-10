import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// StringCast over-the-air localization SDK.
///
/// ```swift
/// StringCast.start(projectId: "p_demo", sdkKey: "pk_demo_local", baseURL: URL(string: "http://localhost:8787")!)
/// label.text = NSLocalizedString("welcome_title", comment: "")   // OTA value
/// label.text = StringCast.string("greeting", default: "Hi %@", name)
/// ```
public enum StringCast {
    /// Posted on the main thread when visible translations change (new release or language change).
    /// `userInfo`: `"version"` (Int), `"language"` (String).
    public static let didUpdateNotification = Notification.Name("StringCastDidUpdateNotification")

    private static let lock = NSLock()
    private static var _engine: StringCastEngine?
    private static var foregroundObserver: NSObjectProtocol?

    static var engine: StringCastEngine? {
        lock.lock(); defer { lock.unlock() }
        return _engine
    }

    // MARK: - Start

    /// Starts the SDK: loads the cache synchronously, then checks for updates in the background.
    public static func start(
        projectId: String,
        sdkKey: String,
        baseURL: URL = StringCastConfig.defaultBaseURL,
        languageOverride: String? = nil,
        draftMode: Bool = StringCastConfig.defaultDraftMode,
        refreshInterval: TimeInterval = 15 * 60
    ) {
        start(StringCastConfig(
            projectId: projectId,
            sdkKey: sdkKey,
            baseURL: baseURL,
            languageOverride: languageOverride,
            draftMode: draftMode,
            refreshInterval: refreshInterval
        ))
    }

    public static func start(_ config: StringCastConfig) {
        Log.enabled = config.loggingEnabled
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = false
        let engine = StringCastEngine(
            config: config,
            store: DiskBundleStore(projectId: config.projectId, rootDirectory: config.cacheDirectory),
            transport: URLSessionTransport(session: URLSession(configuration: sessionConfig)),
            appStrings: MainBundleInterceptor.compiledString
        )
        install(engine)
        if config.swizzleMainBundle { MainBundleInterceptor.install() }
        #if canImport(UIKit) && !os(watchOS)
        if config.refreshOnForeground { observeForeground() }
        #endif
        Task.detached(priority: .utility) {
            await engine.refresh(force: false)
            await engine.autoUploadIfNeeded()   // draft mode only; once per app build
        }
    }

    /// Installs an engine (also used by tests).
    static func install(_ engine: StringCastEngine?) {
        engine?.onChange = { snapshot in
            Observers.notify(version: snapshot.cached?.manifest.version ?? 0, language: snapshot.resolvedLanguage)
        }
        lock.lock()
        let previous = _engine
        _engine = engine
        lock.unlock()
        if previous != nil { Log.debug("StringCast restarted; previous instance replaced") }
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func observeForeground() {
        lock.lock(); defer { lock.unlock() }
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in
            guard let engine = StringCast.engine, engine.config.refreshOnForeground else { return }
            Task.detached(priority: .utility) { await engine.refresh(force: false) }
        }
    }
    #endif

    // MARK: - Lookup

    /// Localized string for `key` (resolved language → base language → app's Localizable.strings →
    /// `default` → key), formatted with `args` after `%s`→`%@` normalisation.
    /// A value whose placeholders don't match `args` is skipped in favour of the next source.
    public static func string(_ key: String, default defaultValue: String? = nil, _ args: CVarArg...) -> String {
        string(key, default: defaultValue, arguments: args)
    }

    public static func string(_ key: String, default defaultValue: String? = nil, arguments args: [CVarArg]) -> String {
        if let engine = engine {
            return engine.string(key, defaultValue: defaultValue, args: args)
        }
        if let compiled = MainBundleInterceptor.compiledString(key), let s = StringCastEngine.formatCompiled(compiled, args: args) {
            return s
        }
        if let d = defaultValue, let s = PlaceholderFormatter.format(d, args: args) { return s }
        return key
    }

    /// Plural lookup using CLDR rules of the language the value came from.
    /// With no `args`, `count` is used as the single format argument.
    public static func pluralString(_ key: String, count: Int, default defaultValue: String? = nil, _ args: CVarArg...) -> String {
        if let engine = engine {
            return engine.pluralString(key, count: count, defaultValue: defaultValue, args: args)
        }
        let a: [CVarArg] = args.isEmpty ? [count] : args
        if let compiled = MainBundleInterceptor.compiledString(key), let s = StringCastEngine.formatCompiled(compiled, args: a) {
            return s
        }
        if let d = defaultValue, let s = PlaceholderFormatter.format(d, args: a) { return s }
        return key
    }

    /// Array value from the OTA bundles (nil if absent). Elements are also reachable as `key.0`, `key.1`, …
    public static func stringArray(_ key: String) -> [String]? {
        engine?.stringArray(key)
    }

    // MARK: - Control

    /// Checks the manifest and downloads new bundles. `force` ignores `refreshInterval`.
    public static func refresh(force: Bool = false) async {
        await engine?.refresh(force: force)
    }

    /// Overrides the language (nil = follow device). Downloads the bundle lazily if needed.
    public static func setLanguage(_ code: String?) {
        engine?.setLanguage(code)
    }

    /// The resolved language code (as spelled by the project), or the device language before start.
    public static var currentLanguage: String {
        engine?.currentLanguage ?? (Locale.preferredLanguages.first ?? "en")
    }

    /// Published release version currently in use (0 = none).
    public static var currentVersion: Int {
        engine?.snapshot.cached?.manifest.version ?? 0
    }

    /// Languages available in the current release.
    public static var availableLanguages: [String] {
        engine?.snapshot.cached?.manifest.languages.map(\.code) ?? []
    }

    /// Draft mode only: uploads every key of `bundle`'s `Localizable` table (`.strings`, `.stringsdict`,
    /// compiled String Catalog) as the project's base language, plus the values of every other project
    /// language found in a matching `.lproj` (`es-MX` → `es-MX.lproj`, else `es.lproj`), one language per
    /// request in batches of 500. The server creates missing keys and fills empty values; it never
    /// overwrites. Runs regardless of the once-per-build marker used by the automatic upload.
    /// Returns the counts summed over all requests.
    @discardableResult
    public static func uploadLocalStrings(from bundle: Bundle = .main) async throws -> UploadResult {
        guard let engine = engine else { throw StringCastError.notStarted }
        guard engine.config.draftMode else { throw StringCastError.draftModeDisabled }
        if engine.snapshot.cached == nil { await engine.refresh(force: false) }
        return try await engine.uploadLocalStrings(bundle: bundle)
    }

    // MARK: - Observers

    /// Registers a closure called on the main thread after each update. Keep the token and call
    /// `cancel()` to unregister (the handler stays registered if the token is discarded).
    @discardableResult
    public static func addObserver(_ handler: @escaping () -> Void) -> StringCastObservation {
        Observers.add(handler)
    }
}

/// Token returned by `StringCast.addObserver(_:)`.
public final class StringCastObservation {
    let id: UUID
    init(id: UUID) { self.id = id }

    public func cancel() { Observers.remove(id) }
}

enum Observers {
    private static let lock = NSLock()
    private static var handlers: [UUID: () -> Void] = [:]

    static func add(_ handler: @escaping () -> Void) -> StringCastObservation {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return StringCastObservation(id: id)
    }

    static func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    static func notify(version: Int, language: String) {
        let deliver = {
            lock.lock()
            let current = Array(handlers.values)
            lock.unlock()
            NotificationCenter.default.post(
                name: StringCast.didUpdateNotification, object: nil,
                userInfo: ["version": version, "language": language]
            )
            current.forEach { $0() }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}
