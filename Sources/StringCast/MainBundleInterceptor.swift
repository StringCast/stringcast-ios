import Foundation
import ObjectiveC

/// Subclass swapped onto `Bundle.main` with `object_setClass` (no stored properties allowed).
///
/// Only the default `Localizable` table is overridden; every other table (InfoPlist, custom
/// tables, storyboard tables such as `Main`) passes straight through to the original implementation.
final class StringCastMainBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard Self.isDefaultTable(tableName), let engine = StringCast.engine else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        let ota = engine.bundleLookup(key) {
            let s = super.localizedString(forKey: key, value: MainBundleInterceptor.sentinel, table: tableName)
            return s == MainBundleInterceptor.sentinel ? nil : s
        }
        return ota ?? super.localizedString(forKey: key, value: value, table: tableName)
    }

    /// The app's own compiled value, bypassing StringCast.
    func stringcastOriginalLocalizedString(forKey key: String, value: String?, table: String?) -> String {
        super.localizedString(forKey: key, value: value, table: table)
    }

    static func isDefaultTable(_ table: String?) -> Bool {
        guard let t = table, !t.isEmpty else { return true }
        return t == "Localizable"
    }
}

enum MainBundleInterceptor {
    static let sentinel = "\u{1}__stringcast_missing__\u{1}"
    private static let lock = NSLock()

    /// Installs the interception once. Returns false if `Bundle.main` was already subclassed by
    /// someone else (we refuse to clobber it).
    @discardableResult
    static func install() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let main = Bundle.main
        let cls: AnyClass = object_getClass(main) ?? Bundle.self
        if cls == StringCastMainBundle.self { return true }
        guard cls == Bundle.self else {
            Log.warn("Bundle.main is already a \(NSStringFromClass(cls)); skipping interception")
            return false
        }
        object_setClass(main, StringCastMainBundle.self)
        Log.debug("intercepting Bundle.main Localizable lookups")
        return true
    }

    /// The app's compiled string for `key` in the Localizable table, or nil if absent.
    static func compiledString(_ key: String) -> String? {
        let main = Bundle.main
        let s: String
        if let intercepted = main as? StringCastMainBundle {
            s = intercepted.stringcastOriginalLocalizedString(forKey: key, value: sentinel, table: nil)
        } else {
            s = main.localizedString(forKey: key, value: sentinel, table: nil)
        }
        return s == sentinel ? nil : s
    }
}
