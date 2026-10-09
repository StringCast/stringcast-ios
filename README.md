# StringCast iOS SDK

Over-the-air localization for iOS apps. Ship your app with its normal `Localizable.strings`, then
update copy and add languages from the StringCast portal. No app release needed.

- Swift Package, iOS 13+ (macOS 11+ / tvOS 13+ also compile), no third-party dependencies.
- Last-known translations load **synchronously** from disk at start, so the first screen is already localized.
- `NSLocalizedString` / `Bundle.main.localizedString` return OTA values automatically. You can opt out of this.
- Network or parse errors are logged and swallowed. Nothing in the SDK should crash the host app.

Full guide: https://console.stringcast.app/docs/ios

## Install (Swift Package Manager)

Xcode → *File › Add Package Dependencies…* → enter `https://github.com/stringcast/stringcast-ios`,
choose *Up to Next Major Version* from `0.1.0`, then add the **StringCast** library to your app target.

`Package.swift`:

```swift
.package(url: "https://github.com/stringcast/stringcast-ios", from: "0.1.0"),
...
.target(name: "MyApp", dependencies: [.product(name: "StringCast", package: "stringcast-ios")])
```

## Start

Call `start` as early as possible, in `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App.init`:

```swift
import StringCast

StringCast.start(
    projectId: "p_8f3k2j",
    sdkKey: "pk_…"                                    // public SDK key
    // baseURL defaults to https://console.stringcast.app (API origin, with or without /v1)
)
```

Every option:

```swift
StringCast.start(StringCastConfig(
    projectId: "p_demo",
    sdkKey: "pk_demo_local",
    baseURL: URL(string: "http://localhost:8787")!,  // simulator → host machine
    languageOverride: nil,          // e.g. "es-MX"; beats device languages
    draftMode: true,                // default: true in DEBUG builds, false in release
    refreshInterval: 15 * 60,       // min seconds between manifest checks
    swizzleMainBundle: true,        // intercept Bundle.main Localizable lookups
    refreshOnForeground: true,      // re-check on willEnterForeground (honours refreshInterval)
    missingKeyDebounce: 5,
    loggingEnabled: nil,            // defaults to draftMode
    cacheDirectory: nil             // defaults to Application Support
))
```

When working against the local backend, add this to your Info.plist so plain `http://localhost` is allowed:

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>
```

### What happens at runtime

1. **Start**: reads `Application Support/StringCast/<projectId>/manifest.json` and `bundles/<lang>.json` synchronously.
2. **Background**: `GET /v1/sdk/<projectId>/manifest` with `If-None-Match`. If the release changed, the SDK downloads
   only the **resolved language** and the **base language**. Each bundle is checked against the manifest
   hash, version and language. Bundles are written atomically, then the manifest, and
   `StringCast.didUpdateNotification` is posted. Other languages are downloaded only when you switch to them.
3. A manifest check is skipped if one ran less than `refreshInterval` ago. `await StringCast.refresh(force: true)` ignores the interval.

## Looking up strings

```swift
// Existing code keeps working. With the swizzle on, these return OTA values:
label.text = NSLocalizedString("welcome_title", comment: "")
let s = Bundle.main.localizedString(forKey: "welcome_title", value: nil, table: nil)

// Explicit API (works with or without the swizzle):
StringCast.string("welcome_title")
StringCast.string("greeting", default: "Hello %@", userName)       // %s in values is converted to %@
StringCast.pluralString("items_count", count: n)                     // CLDR plural rules; args default to [count]
StringCast.stringArray("planets")                                    // ["Mercury", "Venus"]; also "planets.0", "planets.1"
```

**Lookup order:** resolved-language bundle → base-language bundle → the app's own `Localizable.strings` /
`.stringsdict` → `default:` → the key itself.

**Placeholders:** values are stored as uploaded. Before formatting, the SDK converts `%s` to `%@` and `%1$s` to `%1$@`.
It also checks every format string against the arguments you pass (number of arguments and types). Suppose a
translator turns `%d` into `%@`. `String(format:)` would crash on that, so the SDK uses the next fallback source instead.

**Plurals:** the SDK picks the category with CLDR cardinal rules for the language the value came from. Supported languages:
en, de, nl, sv, da, nb, fi, el, hu, tr, es, it, ca, fr, pt / pt-PT, ru, uk, be, pl, cs, sk, hr, sr, bs, ar,
he, ro, lt, lv, sl, ga, cy, is, mk, hi, bn, fa. ja, zh, ko, th, vi, id and ms have no plural forms. Any other
language uses English rules. If the selected category is missing from a value, the SDK uses `other`.

### Updates

```swift
NotificationCenter.default.addObserver(forName: StringCast.didUpdateNotification, object: nil, queue: .main) { _ in
    self.reloadTexts()
}
// Without Combine or NotificationCenter:
let token = StringCast.addObserver { [weak self] in self?.reloadTexts() }   // main thread
token.cancel()
```

UIKit views that were already on screen keep their text until you set it again. Re-assign labels in the observer,
or rebuild the screen.

## Bundle.main interception (swizzling)

`StringCast.start` swaps the class of the `Bundle.main` **instance** for a private subclass using `object_setClass`.
This is the standard approach. No other bundle is touched, and there is no global method exchange.

| Lookup | OTA? |
|---|---|
| `NSLocalizedString("k", comment:)`, `Bundle.main.localizedString(forKey:value:table: nil / "Localizable")` | ✅ |
| Your own UIKit code that calls the above | ✅ |
| Other tables (`InfoPlist`, `Main` storyboard tables, custom `tableName:`) | ❌ passed through untouched |
| Storyboard / XIB text (UIKit looks it up in the *storyboard's* table, e.g. `Main.strings`) | ❌ set it in code with `NSLocalizedString` |
| Keys whose OTA value is a **plural** | Uses the compiled `.stringsdict` (call `StringCast.pluralString`) |
| `String(localized:)` / SwiftUI `Text("key")` | Usually. These go through Bundle on most iOS versions, but Apple doesn't guarantee it |

Opt out with `StringCastConfig(swizzleMainBundle: false)` and use `StringCast.string(...)` explicitly.
If some other library has already subclassed `Bundle.main`, StringCast leaves it alone and logs a warning.

## SwiftUI

Plain `Text("welcome_title")` creates a `LocalizedStringKey`. SwiftUI resolves it through `Bundle.main` on most
iOS versions, so the swizzle usually applies. That isn't guaranteed, though, and SwiftUI won't re-render when a
release arrives. Use the helpers instead:

```swift
struct WelcomeView: View {
    @ObservedObject private var stringcast = StringCastStore.shared   // re-renders on every update

    var body: some View {
        VStack {
            Text(stringcast: "welcome_title")
            Text(stringcast: "items_count", count: items.count)
            Text(verbatim: stringcast.string("language_label", StringCast.currentLanguage))
            StringCastText("welcome_body")         // observes the store itself; usable anywhere
        }
    }
}
```

`StringCastStore` is an `ObservableObject` that publishes `revision`, `language` and `version`.

## Language resolution

Contract §6.4. `StringCast.currentLanguage` returns the result.

1. `languageOverride`, or `StringCast.setLanguage("es")`, beats everything. It is matched with the rules below. Pass `nil` to follow the device again.
   The override is kept in memory only. To make an in-app language picker persistent, store the choice yourself and pass it as `languageOverride`.
2. Otherwise the SDK goes through `Locale.preferredLanguages` in order. For each one it tries:
   an exact match (`es-MX`), then language plus script (`zh-Hant-TW` → `zh-Hant`), then language only (`es`), then any
   project language with the same language subtag (`pt-PT` → `pt-BR`). The first hit wins.
3. If nothing matches, the project's `baseLanguage` is used.

Codes are compared case-insensitively, with `_` treated as `-`.

## Draft mode

Draft mode defaults to `true` in DEBUG builds. SPM compiles the package with your app's configuration, so it follows
your Debug/Release setting. **Never enable it in App Store builds.** The SDK key is public, but there is no reason
to let production clients create keys.

- **Missing keys:** a key you look up at runtime that isn't in the base bundle, and that has a local value
  (compiled string or `default:`), is reported to `POST /v1/sdk/<id>/missing`. Reports are debounced
  (5 s), batched (≤ 500) and sent once per key per launch. Existing keys are never overwritten.
- **Upload everything:**

  ```swift
  let result = try await StringCast.uploadLocalStrings()   // created / ignored counts
  ```

  This reads `Localizable.strings` (text or compiled), `Localizable.stringsdict` and `Localizable.xcstrings` (if
  bundled) from `Bundle.main`'s development-region `.lproj`, then posts the base values in batches of 500.
  String Catalogs are compiled into `.strings`/`.stringsdict` at build time, so those are what the SDK finds in the app.

## Uploading strings from an Xcode build phase (CLI)

For CI, or for uploading on every build, use the CLI with the secret upload key (`sk_…`). Never put that key in the app.
Add a **Run Script** build phase, usually limited to Debug:

```sh
if [ "${CONFIGURATION}" = "Debug" ] && [ -n "${STRINGCAST_UPLOAD_KEY}" ]; then
  export STRINGCAST_PROJECT_ID=p_demo
  export STRINGCAST_BASE_URL=http://localhost:8787
  npx stringcast push --platform ios --path "${SRCROOT}/MyApp" || echo "warning: stringcast push failed"
fi
```

`--path` is the folder that contains your `*.lproj` directories (and/or `*.xcstrings`). Set `STRINGCAST_UPLOAD_KEY` in
your environment or CI secrets. In Xcode 15+, either set `ENABLE_USER_SCRIPT_SANDBOXING = NO` or list the
`.lproj` files as script inputs. `npx stringcast pull --platform ios --path …` writes translations back as
`.lproj/Localizable.strings` so they can ship as the offline fallback.

## What the SDK sends

Manifest checks (`GET /v1/sdk/{projectId}/manifest`) and draft-mode reports (`POST /v1/sdk/{projectId}/missing`) go
to `baseURL` (default `https://console.stringcast.app`) with your public SDK key (`X-Api-Key`) and these check-in
headers, so the portal can show which apps are connected (contract §4.2):

| Header | Value |
|---|---|
| `X-StringCast-Platform` | `ios` |
| `X-StringCast-App-Id` | your bundle ID (`Bundle.main.bundleIdentifier`) |
| `X-StringCast-App-Version` | `CFBundleShortVersionString` |
| `X-StringCast-SDK-Version` | `StringCast.sdkVersion`, e.g. `0.1.0` |
| `X-StringCast-Language` | the language the SDK resolved for this device, e.g. `es` (omitted until known) |

No device IDs (IDFA/IDFV), user identifiers or other personal data are sent. Empty values are omitted and values are
restricted to printable ASCII. Bundle downloads (CDN URLs from the manifest) never carry check-in headers, so they stay
cacheable; the API key is only attached to bundle URLs on the `baseURL` host (local backend).

## Cache & threading

- Cache location: `Application Support/StringCast/<projectId>/` (`manifest.json` + `bundles/<lang>.json`), excluded
  from iCloud backup. Writes are atomic: bundles are written first, then the manifest.
- Lookups are callable from any thread. Each one takes a single short lock to read an immutable snapshot.
  Network work runs on Swift concurrency tasks. Notifications and observers are delivered on the main thread.

## Example app

`Examples/StringCastDemo/StringCastDemo.xcodeproj` is a SwiftUI app (iOS 15+). It depends on this package as a local
package and is configured for `http://localhost:8787`, `p_demo` and `pk_demo_local`.

```sh
# Point StringCastDemoApp.swift at https://console.stringcast.app and your own project/SDK key, then:
open Examples/StringCastDemo/StringCastDemo.xcodeproj   # Run on an iOS Simulator
# or headless:
xcodebuild -project Examples/StringCastDemo/StringCastDemo.xcodeproj -scheme StringCastDemo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/stringcast-dd build
```

## Development

```sh
swift build
swift test          # 49 XCTest cases (resolution, placeholders, decoding, plurals, engine, refresh, swizzle, check-in headers)
STRINGCAST_LIVE=1 swift test --filter LiveBackendTests   # read-only smoke test against localhost:8787
xcodebuild -scheme StringCast -destination 'generic/platform=iOS Simulator' build
```

If the checkout lives in an iCloud-synced folder (e.g. `~/Documents`), keep build products elsewhere, for example
`swift build --scratch-path /tmp/stringcast-spm` and `xcodebuild -derivedDataPath /tmp/stringcast-dd`. Otherwise
iCloud's extended attributes break code signing.
