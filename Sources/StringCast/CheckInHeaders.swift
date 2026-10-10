import Foundation

extension StringCast {
    /// SDK version, sent as `X-StringCast-SDK-Version` (contract §4.2).
    public static let sdkVersion = "0.1.1"
}

/// Check-in headers (contract §4.2), sent on `/manifest` and `/missing` only — never on bundle
/// downloads (CDN). They identify the app, not the user: no device IDs or personal data.
enum CheckInHeaders {
    static let platform = "ios"

    static let platformHeader = "X-StringCast-Platform"
    static let appIdHeader = "X-StringCast-App-Id"
    static let appVersionHeader = "X-StringCast-App-Version"
    static let sdkVersionHeader = "X-StringCast-SDK-Version"
    static let languageHeader = "X-StringCast-Language"

    /// Static app identity (bundle ID + marketing version).
    struct AppInfo: Equatable {
        var appId: String?
        var appVersion: String?

        static func from(_ bundle: Bundle) -> AppInfo {
            AppInfo(
                appId: bundle.bundleIdentifier,
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
        }
    }

    /// Builds the header map; nil/empty values (after ASCII sanitising) are omitted.
    static func build(app: AppInfo, sdkVersion: String = StringCast.sdkVersion, language: String?) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ name: String, _ value: String?) {
            let v = asciiSafe(value)
            if !v.isEmpty { out[name] = v }
        }
        put(platformHeader, platform)
        put(appIdHeader, app.appId)
        put(appVersionHeader, app.appVersion)
        put(sdkVersionHeader, sdkVersion)
        put(languageHeader, language)
        return out
    }

    /// Keeps printable ASCII only (HTTP header values must be ASCII-safe), trimmed.
    static func asciiSafe(_ value: String?) -> String {
        guard let value = value else { return "" }
        let scalars = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }
}
