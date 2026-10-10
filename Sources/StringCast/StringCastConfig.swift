import Foundation

/// Configuration for `StringCast.start(_:)`.
public struct StringCastConfig {
    /// Default hosted API (`https://console.stringcast.app`). Override for local dev (e.g. `http://localhost:8787`).
    public static let defaultBaseURL = URL(string: "https://console.stringcast.app")!

    /// Draft mode default, decided **at runtime** from how the app was installed (not from `#if DEBUG`,
    /// which Xcode evaluates without `DEBUG` for packages built in custom configurations such as QA/CI):
    ///
    /// - `true` in the iOS Simulator,
    /// - `true` when the app contains `embedded.mobileprovision` (development, ad-hoc and enterprise builds),
    /// - `true` for TestFlight installs (`appStoreReceiptURL` ends in `sandboxReceipt`),
    /// - `false` otherwise, i.e. **App Store installs are never in draft mode by default**.
    ///
    /// Pass `draftMode:` explicitly to override (e.g. `false` for an ad-hoc build handed to customers).
    public static var defaultDraftMode: Bool { DraftModeDetector.isDraftMode(.current) }

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
    /// Intercept `-[NSBundle localizedStringForKey:value:table:]` so `NSLocalizedString`,
    /// `Bundle.localizedString(forKey:value:table:)` & co. return OTA values. Since 0.1.2 this covers
    /// **every bundle inside the app** (`Bundle.main`, Swift-package resource bundles, embedded
    /// frameworks) and every table, not only `Bundle.main`'s `Localizable`. System bundles are untouched.
    /// The name is kept for source compatibility.
    public var swizzleMainBundle: Bool
    /// Check for updates when the app returns to the foreground (honours `refreshInterval`).
    public var refreshOnForeground: Bool
    /// Debounce for draft-mode missing-key reports.
    public var missingKeyDebounce: TimeInterval
    /// Log to the console (defaults to `draftMode`).
    public var loggingEnabled: Bool
    /// Override the cache root (defaults to Application Support). `StringCast/<projectId>/` is appended.
    public var cacheDirectory: URL?
    /// Draft mode only: once per app build (version + build number + SDK version), upload every key of
    /// every table of every app bundle (`Bundle.main`, Swift-package resource bundles, embedded
    /// frameworks) plus the existing translations of each project language.
    public var autoUploadLocalStrings: Bool
    /// Keys never uploaded or reported as missing (e.g. debug-only or generated keys).
    public var excludedKeys: Set<String>

    public init(
        projectId: String,
        sdkKey: String,
        baseURL: URL = StringCastConfig.defaultBaseURL,
        languageOverride: String? = nil,
        draftMode: Bool = StringCastConfig.defaultDraftMode,
        refreshInterval: TimeInterval = 15 * 60,
        swizzleMainBundle: Bool = true,
        refreshOnForeground: Bool = true,
        missingKeyDebounce: TimeInterval = 5,
        loggingEnabled: Bool? = nil,
        cacheDirectory: URL? = nil,
        autoUploadLocalStrings: Bool = true,
        excludedKeys: Set<String> = []
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
        self.autoUploadLocalStrings = autoUploadLocalStrings
        self.excludedKeys = excludedKeys
    }
}

enum Log {
    static var enabled = false

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[StringCast] %@", message())
    }

    /// Always printed (problems the integrator must see even with logging off).
    static func warn(_ message: @autoclosure () -> String) {
        NSLog("[StringCast] warning: %@", message())
    }

    /// Always printed. Reserved for rare, one-off facts (e.g. the once-per-build upload summary).
    static func notice(_ message: @autoclosure () -> String) {
        NSLog("[StringCast] %@", message())
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

/// Runtime heuristic behind `StringCastConfig.defaultDraftMode`. The probes are injectable for tests.
enum DraftModeDetector {
    struct Environment: Equatable {
        /// Running in the iOS/tvOS Simulator.
        var isSimulator: Bool
        /// The app bundle contains `embedded.mobileprovision` (development, ad-hoc, enterprise).
        var hasEmbeddedProvisioningProfile: Bool
        /// `Bundle.main.appStoreReceiptURL?.lastPathComponent` (`sandboxReceipt` on TestFlight).
        var receiptName: String?

        static var current: Environment {
            Environment(
                isSimulator: isSimulatorBuild,
                hasEmbeddedProvisioningProfile: Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil,
                receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent
            )
        }
    }

    /// `targetEnvironment` is about the architecture the package is compiled for, so it is correct inside packages.
    static var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func isDraftMode(_ env: Environment) -> Bool {
        env.isSimulator || env.hasEmbeddedProvisioningProfile || env.receiptName == "sandboxReceipt"
    }
}
