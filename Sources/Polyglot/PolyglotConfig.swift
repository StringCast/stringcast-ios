import Foundation

/// Configuration for `Polyglot.start(_:)`.
public struct PolyglotConfig {
    /// Default hosted API. Override with your deployment (e.g. `http://localhost:8787` in dev).
    public static let defaultBaseURL = URL(string: "https://api.polyglot.dev")!

    /// Draft mode default: on in DEBUG builds of the package (SPM compiles the package with the
    /// app's configuration, so this follows the app's Debug/Release setting), never in release.
    public static var defaultDraftMode: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public var projectId: String
    /// Public SDK key (`pk_…`).
    public var sdkKey: String
    /// API origin, with or without the trailing `/v1`.
    public var baseURL: URL
    /// Forces a language (BCP-47); beats device preferences.
    public var languageOverride: String?
    /// Reports unknown keys to `/missing` and enables `uploadLocalStrings()`.
    public var draftMode: Bool
    /// Minimum seconds between manifest checks (default 15 min). `refresh(force: true)` ignores it.
    public var refreshInterval: TimeInterval
    /// Swap `Bundle.main`'s class so `NSLocalizedString` & co. return OTA values.
    public var swizzleMainBundle: Bool
    /// Check for updates when the app returns to the foreground (honours `refreshInterval`).
    public var refreshOnForeground: Bool
    /// Debounce for draft-mode missing-key reports.
    public var missingKeyDebounce: TimeInterval
    /// Log to the console (defaults to `draftMode`).
    public var loggingEnabled: Bool
    /// Override the cache root (defaults to Application Support). `Polyglot/<projectId>/` is appended.
    public var cacheDirectory: URL?

    public init(
        projectId: String,
        sdkKey: String,
        baseURL: URL = PolyglotConfig.defaultBaseURL,
        languageOverride: String? = nil,
        draftMode: Bool = PolyglotConfig.defaultDraftMode,
        refreshInterval: TimeInterval = 15 * 60,
        swizzleMainBundle: Bool = true,
        refreshOnForeground: Bool = true,
        missingKeyDebounce: TimeInterval = 5,
        loggingEnabled: Bool? = nil,
        cacheDirectory: URL? = nil
    ) {
        self.projectId = projectId
        self.sdkKey = sdkKey
        self.baseURL = baseURL
        self.languageOverride = languageOverride
        self.draftMode = draftMode
        self.refreshInterval = refreshInterval
        self.swizzleMainBundle = swizzleMainBundle
        self.refreshOnForeground = refreshOnForeground
        self.missingKeyDebounce = missingKeyDebounce
        self.loggingEnabled = loggingEnabled ?? draftMode
        self.cacheDirectory = cacheDirectory
    }
}

enum Log {
    static var enabled = false

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[Polyglot] %@", message())
    }

    static func warn(_ message: @autoclosure () -> String) {
        NSLog("[Polyglot] warning: %@", message())
    }
}

extension NSLock {
    /// Scoped locking usable from async contexts (never held across a suspension point).
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
