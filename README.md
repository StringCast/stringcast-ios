# Polyglot iOS SDK

Over-the-air localization for iOS apps. Ship your app with its normal `Localizable.strings`, then
update copy and add languages from the Polyglot portal. No app release needed.

- Swift Package, iOS 13+ (macOS 11+ / tvOS 13+ also compile), no third-party dependencies.
- Last-known translations load **synchronously** from disk at start, so the first screen is already localized.
- `NSLocalizedString` / `Bundle.main.localizedString` return OTA values automatically. You can opt out of this.
- Network or parse errors are logged and swallowed. Nothing in the SDK should crash the host app.

Implements `docs/CONTRACT.md` §6.

## Install (Swift Package Manager)

Xcode → *File › Add Package Dependencies…* → enter the repository URL (or *Add Local…* and pick `sdk-ios/`),
then add the **Polyglot** library to your app target.

`Package.swift`:

```swift
.package(url: "https://github.com/<org>/polyglot", from: "1.0.0"),   // or .package(path: "../polyglot/sdk-ios")
...
.target(name: "MyApp", dependencies: [.product(name: "Polyglot", package: "polyglot")])
```

## Start

Call `start` as early as possible, in `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App.init`:

```swift
import Polyglot

Polyglot.start(
    projectId: "p_8f3k2j",
    sdkKey: "pk_…",                                   // public SDK key
    baseURL: URL(string: "https://api.example.com")!  // API origin, with or without /v1
)
```

Every option:

```swift
Polyglot.start(PolyglotConfig(
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

1. **Start**: reads `Application Support/Polyglot/<projectId>/manifest.json` and `bundles/<lang>.json` synchronously.
2. **Background**: `GET /v1/sdk/<projectId>/manifest` with `If-None-Match`. If the release changed, the SDK downloads
   only the **resolved language** and the **base language**. Each bundle is checked against the manifest
   hash, version and language. Bundles are written atomically, then the manifest, and
   `Polyglot.didUpdateNotification` is posted. Other languages are downloaded only when you switch to them.
3. A manifest check is skipped if one ran less than `refreshInterval` ago. `await Polyglot.refresh(force: true)` ignores the interval.

## Looking up strings

```swift
// Existing code keeps working. With the swizzle on, these return OTA values:
label.text = NSLocalizedString("welcome_title", comment: "")
let s = Bundle.main.localizedString(forKey: "welcome_title", value: nil, table: nil)

// Explicit API (works with or without the swizzle):
Polyglot.string("welcome_title")
Polyglot.string("greeting", default: "Hello %@", userName)       // %s in values is converted to %@
Polyglot.pluralString("items_count", count: n)                     // CLDR plural rules; args default to [count]
Polyglot.stringArray("planets")                                    // ["Mercury", "Venus"]; also "planets.0", "planets.1"
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
NotificationCenter.default.addObserver(forName: Polyglot.didUpdateNotification, object: nil, queue: .main) { _ in
    self.reloadTexts()
}
// Without Combine or NotificationCenter:
let token = Polyglot.addObserver { [weak self] in self?.reloadTexts() }   // main thread
token.cancel()
```

UIKit views that were already on screen keep their text until you set it again. Re-assign labels in the observer,
or rebuild the screen.

## Bundle.main interception (swizzling)

`Polyglot.start` swaps the class of the `Bundle.main` **instance** for a private subclass using `object_setClass`.
This is the standard approach. No other bundle is touched, and there is no global method exchange.

| Lookup | OTA? |
|---|---|
| `NSLocalizedString("k", comment:)`, `Bundle.main.localizedString(forKey:value:table: nil / "Localizable")` | ✅ |
| Your own UIKit code that calls the above | ✅ |
| Other tables (`InfoPlist`, `Main` storyboard tables, custom `tableName:`) | ❌ passed through untouched |
| Storyboard / XIB text (UIKit looks it up in the *storyboard's* table, e.g. `Main.strings`) | ❌ set it in code with `NSLocalizedString` |
| Keys whose OTA value is a **plural** | Uses the compiled `.stringsdict` (call `Polyglot.pluralString`) |
| `String(localized:)` / SwiftUI `Text("key")` | Usually. These go through Bundle on most iOS versions, but Apple doesn't guarantee it |

Opt out with `PolyglotConfig(swizzleMainBundle: false)` and use `Polyglot.string(...)` explicitly.
If some other library has already subclassed `Bundle.main`, Polyglot leaves it alone and logs a warning.

## SwiftUI

Plain `Text("welcome_title")` creates a `LocalizedStringKey`. SwiftUI resolves it through `Bundle.main` on most
iOS versions, so the swizzle usually applies. That isn't guaranteed, though, and SwiftUI won't re-render when a
release arrives. Use the helpers instead:

```swift
struct WelcomeView: View {
    @ObservedObject private var polyglot = PolyglotStore.shared   // re-renders on every update

    var body: some View {
        VStack {
            Text(polyglot: "welcome_title")
            Text(polyglot: "items_count", count: items.count)
            Text(verbatim: polyglot.string("language_label", Polyglot.currentLanguage))
            PolyglotText("welcome_body")         // observes the store itself; usable anywhere
        }
    }
}
```

`PolyglotStore` is an `ObservableObject` that publishes `revision`, `language` and `version`.

## Language resolution

Contract §6.4. `Polyglot.currentLanguage` returns the result.

1. `languageOverride`, or `Polyglot.setLanguage("es")`, beats everything. It is matched with the rules below. Pass `nil` to follow the device again.
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
  let result = try await Polyglot.uploadLocalStrings()   // created / ignored counts
  ```

  This reads `Localizable.strings` (text or compiled), `Localizable.stringsdict` and `Localizable.xcstrings` (if
  bundled) from `Bundle.main`'s development-region `.lproj`, then posts the base values in batches of 500.
  String Catalogs are compiled into `.strings`/`.stringsdict` at build time, so those are what the SDK finds in the app.

## Uploading strings from an Xcode build phase (CLI)

For CI, or for uploading on every build, use the CLI with the secret upload key (`sk_…`). Never put that key in the app.
Add a **Run Script** build phase, usually limited to Debug:

```sh
if [ "${CONFIGURATION}" = "Debug" ] && [ -n "${POLYGLOT_UPLOAD_KEY}" ]; then
  export POLYGLOT_PROJECT_ID=p_demo
  export POLYGLOT_BASE_URL=http://localhost:8787
  npx polyglot push --platform ios --path "${SRCROOT}/MyApp" || echo "warning: polyglot push failed"
fi
```

`--path` is the folder that contains your `*.lproj` directories (and/or `*.xcstrings`). Set `POLYGLOT_UPLOAD_KEY` in
your environment or CI secrets. In Xcode 15+, either set `ENABLE_USER_SCRIPT_SANDBOXING = NO` or list the
`.lproj` files as script inputs. `npx polyglot pull --platform ios --path …` writes translations back as
`.lproj/Localizable.strings` so they can ship as the offline fallback.

## Cache & threading

- Cache location: `Application Support/Polyglot/<projectId>/` (`manifest.json` + `bundles/<lang>.json`), excluded
  from iCloud backup. Writes are atomic: bundles are written first, then the manifest.
- Lookups are callable from any thread. Each one takes a single short lock to read an immutable snapshot.
  Network work runs on Swift concurrency tasks. Notifications and observers are delivered on the main thread.

## Example app

`Examples/PolyglotDemo/PolyglotDemo.xcodeproj` is a SwiftUI app (iOS 15+). It depends on this package as a local
package and is configured for `http://localhost:8787`, `p_demo` and `pk_demo_local`.

```sh
cd backend && npm run seed && npm run dev           # in the repo root, see docs/CONTRACT.md §5
open sdk-ios/Examples/PolyglotDemo/PolyglotDemo.xcodeproj   # Run on an iOS Simulator
# or headless:
xcodebuild -project sdk-ios/Examples/PolyglotDemo/PolyglotDemo.xcodeproj -scheme PolyglotDemo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/polyglot-dd build
```

## Development

```sh
swift build
swift test          # 45 XCTest cases (resolution, placeholders, decoding, plurals, engine, refresh, swizzle)
POLYGLOT_LIVE=1 swift test --filter LiveBackendTests   # read-only smoke test against localhost:8787
xcodebuild -scheme Polyglot -destination 'generic/platform=iOS Simulator' build
```

If the checkout lives in an iCloud-synced folder (e.g. `~/Documents`), keep build products elsewhere, for example
`swift build --scratch-path /tmp/polyglot-spm` and `xcodebuild -derivedDataPath /tmp/polyglot-dd`. Otherwise
iCloud's extended attributes break code signing.
