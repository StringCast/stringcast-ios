import Foundation

/// Strings looked up the way feature modules usually do it: through `Bundle.module` and a custom table.
/// Nothing here knows about StringCast.
public enum DemoFeature {
    /// `NSLocalizedString` with a table and the package's resource bundle.
    public static func title() -> String {
        NSLocalizedString("feature_title", tableName: "Feature", bundle: .module, comment: "Feature screen title")
    }

    /// `String(localized:table:bundle:)` (iOS 15+).
    public static func body() -> String {
        String(localized: "feature_body", table: "Feature", bundle: .module, comment: "Feature screen body")
    }

    /// The resource bundle's location (shown in the demo UI).
    public static var bundleName: String { Bundle.module.bundleURL.lastPathComponent }
}
