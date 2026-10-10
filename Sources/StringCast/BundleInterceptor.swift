import Foundation
import ObjectiveC

extension Bundle {
    /// Replacement for `-[NSBundle localizedStringForKey:value:table:]`, exchanged once by
    /// `BundleInterceptor.install()`. After the exchange, calling this selector runs the ORIGINAL
    /// implementation (that is how the recursion below reaches Apple's code).
    @objc func stringcast_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let ota = BundleInterceptor.otaValue(bundle: self, key: key, table: tableName) { return ota }
        return stringcast_localizedString(forKey: key, value: value, table: tableName)
    }
}

/// Global interception of `-[NSBundle localizedStringForKey:value:table:]` for app-owned bundles.
///
/// - Installed once per process with `method_exchangeImplementations` (thread-safe, idempotent).
/// - A receiver is intercepted only if its `bundlePath` lies inside the app bundle (`Bundle.main`):
///   the app itself, Swift-package resource bundles and embedded frameworks. The decision is cached
///   per bundle path. System bundles take the fast path straight to the original implementation.
/// - Every table is intercepted except `InfoPlist` and storyboard/XIB tables.
/// - OTA values come from the flat key namespace of the release (any table). Plural OTA values return
///   nil so the compiled `.stringsdict` keeps working with `String(format:)`.
enum BundleInterceptor {
    static let sentinel = "\u{1}__stringcast_missing__\u{1}"

    struct BundleInfo: Equatable {
        var isApp: Bool
        /// Tables passed through untouched (InfoPlist, storyboard/XIB tables).
        var skippedTables: Set<String>
    }

    private static let lock = NSLock()
    private static var exchanged = false
    private static var active = false
    private static var cache: [String: BundleInfo] = [:]
    private static var rootOverride: String?
    private static var cachedRoot: String?

    private static let exchange: Bool = {
        let cls: AnyClass = Bundle.self
        guard let original = class_getInstanceMethod(cls, #selector(Bundle.localizedString(forKey:value:table:))),
              let replacement = class_getInstanceMethod(cls, #selector(Bundle.stringcast_localizedString(forKey:value:table:))) else {
            Log.warn("could not find -[NSBundle localizedStringForKey:value:table:]; interception disabled")
            return false
        }
        method_exchangeImplementations(original, replacement)
        lock.locked { exchanged = true }
        return true
    }()

    /// Installs the interception (once per process) and enables it. Returns false if it could not be installed.
    @discardableResult
    static func install() -> Bool {
        let ok = exchange
        lock.locked { active = ok }
        if ok { Log.debug("intercepting localized strings of app bundles (all tables)") }
        return ok
    }

    /// Turns interception off (`swizzleMainBundle: false` after an earlier start). The exchange stays in
    /// place but every call takes the pass-through path.
    static func disable() { lock.locked { active = false } }

    static var isActive: Bool { lock.locked { active } }

    /// Tests: treat `path` as the app bundle instead of `Bundle.main` (nil restores). Clears the cache.
    static func setAppRootForTesting(_ path: String?) {
        lock.locked {
            rootOverride = path.map(AppBundles.canonicalPath)
            cachedRoot = nil
            cache.removeAll()
        }
    }

    private static var appRoot: String {
        if let r = lock.locked({ rootOverride ?? cachedRoot }) { return r }
        let r = AppBundles.canonicalPath(Bundle.main.bundlePath)
        lock.locked { if rootOverride == nil { cachedRoot = r } }
        return lock.locked { rootOverride ?? r }
    }

    /// Cached per bundle path; the disk scan for storyboard tables runs once per app bundle.
    static func info(for bundle: Bundle) -> BundleInfo {
        let path = bundle.bundlePath
        if let hit = lock.locked({ cache[path] }) { return hit }
        let root = appRoot
        let canonical = AppBundles.canonicalPath(path)
        let isApp = AppBundles.isInside(canonical, root: root)
            && !AppBundles.ownBundleNames.contains((canonical as NSString).lastPathComponent)
        let skipped = isApp ? LocalStringsReader.excludedTables.union(LocalStringsReader.tables(in: bundle).uiTables) : []
        let info = BundleInfo(isApp: isApp, skippedTables: skipped)
        lock.locked { cache[path] = info }
        return info
    }

    static func tableName(_ table: String?) -> String {
        guard let t = table, !t.isEmpty else { return "Localizable" }
        return t
    }

    /// The OTA value the swizzled method returns, or nil to run the original implementation.
    static func otaValue(bundle: Bundle, key: String, table: String?) -> String? {
        guard isActive, let engine = StringCast.engine else { return nil }
        let info = info(for: bundle)
        guard info.isApp, !info.skippedTables.contains(tableName(table)) else { return nil }
        return engine.bundleLookup(key) {
            let s = original(bundle, key: key, value: sentinel, table: table)
            return s == sentinel ? nil : s
        }
    }

    /// Apple's implementation, bypassing StringCast (never recurses into the interception).
    static func original(_ bundle: Bundle, key: String, value: String?, table: String?) -> String {
        if lock.locked({ exchanged }) {
            return bundle.stringcast_localizedString(forKey: key, value: value, table: table)
        }
        return bundle.localizedString(forKey: key, value: value, table: table)
    }

    /// The app's compiled string for `key` in `Bundle.main`'s Localizable table, or nil if absent.
    static func compiledString(_ key: String) -> String? {
        let s = original(.main, key: key, value: sentinel, table: nil)
        return s == sentinel ? nil : s
    }
}
