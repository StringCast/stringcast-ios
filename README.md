# StringCast iOS SDK

Over-the-air localization for iOS apps. Ship your app with its normal `.strings` / `.stringsdict` / String
Catalogs (in the app target, Swift packages or embedded frameworks), then update copy and add languages from
the StringCast portal. No app release needed.

- Swift Package, iOS 13+ (macOS 11+ / tvOS 13+ also compile), no third-party dependencies.
- Last-known translations load **synchronously** from disk at start, so the first screen is already localized.
- `NSLocalizedString` / `Bundle.localizedString(forKey:value:table:)` return OTA values automatically, for every
  bundle inside your app (main bundle, Swift-package `Bundle.module`, embedded frameworks) and every table. You can opt out of this.
- Network or parse errors are logged and swallowed. Nothing in the SDK should crash the host app.

Full guide: https://console.stringcast.app/docs/ios

## Install (Swift Package Manager)

Xcode → *File › Add Package Dependencies…* → enter `https://github.com/stringcast/stringcast-ios`,
choose *Up to Next Major Version* from `0.1.2`, then add the **StringCast** library to your app target.

`Package.swift`:

```swift
.package(url: "https://github.com/stringcast/stringcast-ios", from: "0.1.2"),
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
    draftMode: true,                // default: decided at runtime; false for App Store installs (see Draft mode)
    refreshInterval: 15 * 60,       // min seconds between manifest checks
    swizzleMainBundle: true,        // intercept lookups in all app bundles and tables (name kept from 0.1.0)
    refreshOnForeground: true,      // re-check on willEnterForeground (honours refreshInterval)
    missingKeyDebounce: 5,
    loggingEnabled: nil,            // defaults to draftMode
    cacheDirectory: nil,            // defaults to Application Support
    autoUploadLocalStrings: true,   // draft mode: upload all local strings (all app bundles/tables) once per build
    excludedKeys: []                // keys never uploaded / reported
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
// Existing code keeps working. With the interception on, these return OTA values:
label.text = NSLocalizedString("welcome_title", comment: "")
let s = Bundle.main.localizedString(forKey: "welcome_title", value: nil, table: nil)
// …also in feature modules, custom tables and SwiftGen accessors built on NSLocalizedString:
title = NSLocalizedString("feature_title", tableName: "Feature", bundle: .module, comment: "")

// Explicit API (works with or without the swizzle):
StringCast.string("welcome_title")
StringCast.string("greeting", default: "Hello %@", userName)       // %s in values is converted to %@
StringCast.pluralString("items_count", count: n)                     // CLDR plural rules; args default to [count]
StringCast.stringArray("planets")                                    // ["Mercury", "Venus"]; also "planets.0", "planets.1"
```

**Lookup order:** resolved-language bundle → base-language bundle → the app's own `Localizable.strings` /
`.stringsdict` (`Bundle.main`) → `default:` → the key itself.

OTA keys live in **one flat namespace**: a release value for `feature_title` applies whichever bundle and
table the app looks it up in. Keep keys unique across tables and modules (the upload logs collisions).

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

## Interception of app bundles (swizzling)

`StringCast.start` exchanges the implementation of `-[NSBundle localizedStringForKey:value:table:]` once per
process (thread-safe, idempotent). The replacement only acts when the receiver is an **app-owned bundle**,
i.e. its `bundlePath` is inside `Bundle.main.bundlePath`: the app itself, Swift-package resource bundles
(`<Package>_<Target>.bundle`, what `Bundle.module` points to) and embedded frameworks
(`Frameworks/*.framework`, `X.framework/Y.bundle`). The decision is cached per bundle path, so system bundles
(UIKit, Foundation, …) take a cheap pass-through path. When the release has a value for the key, it is
returned; otherwise Apple's original implementation runs. The SDK's own compiled-string fallbacks always call
the original implementation, so there is no recursion.

| Lookup | OTA? |
|---|---|
| `NSLocalizedString("k", comment:)`, `Bundle.main.localizedString(forKey:value:table:)` | ✅ |
| `NSLocalizedString("k", tableName: "Auth", bundle: .module, comment:)` (Swift packages, any table) | ✅ |
| `bundle.localizedString(forKey:value:table:)` on an embedded framework's bundle | ✅ |
| SwiftGen / R.swift accessors (they call `NSLocalizedString` / `bundle.localizedString`) | ✅ |
| Your own UIKit code that calls the above | ✅ |
| `InfoPlist` table (permission prompts, display name: read by the system, out of process) | ❌ passed through |
| Storyboard / XIB text (UIKit looks it up in the *storyboard's* table, e.g. `Main.strings`) | ❌ passed through; set it in code with `NSLocalizedString` |
| Keys whose OTA value is a **plural** | Uses the compiled `.stringsdict` (call `StringCast.pluralString`) |
| `String(localized:)`, `LocalizedStringResource`, SwiftUI `Text("key")` / `Text("key", bundle:)` | ❌ on current iOS versions these go through a private Foundation entry point, not `localizedStringForKey:value:table:`. Use `NSLocalizedString`, `Text(stringcast:)` or `StringCast.string` for OTA text. Their keys are still **uploaded** |
| Bundles outside the app (system frameworks) | ❌ never touched |

Opt out with `StringCastConfig(swizzleMainBundle: false)` and use `StringCast.string(...)` explicitly. The flag
keeps its 0.1.0 name for source compatibility, but since 0.1.2 it controls the interception of **all app bundles**.
Bundle subclasses (including other libraries' `Bundle.main` class swaps) keep working as long as they call `super`.

## SwiftUI

Plain `Text("welcome_title")` creates a `LocalizedStringKey`. Current iOS versions resolve it through a private
Foundation entry point that the interception does not see, and SwiftUI wouldn't re-render when a release
arrives anyway. Use the helpers instead:

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

Draft mode makes the SDK upload your app's strings and report keys missing from the base bundle. Its default
is decided **at runtime** from how the app is installed:

| Install | `StringCastConfig.defaultDraftMode` |
|---|---|
| iOS Simulator (any build configuration) | `true` |
| App with `embedded.mobileprovision`: Xcode development builds, ad-hoc, enterprise / in-house (QA, CI builds) | `true` |
| TestFlight (`appStoreReceiptURL` ends in `sandboxReceipt`) | `true` |
| **App Store** | **`false`, always** |

Before 0.1.2 the default was `#if DEBUG` inside the package. Xcode compiles Swift packages without `DEBUG` for
any configuration other than *Debug* (QA, Staging, CI…), so those builds were silently not in draft mode and
never uploaded anything. Override it when you need to, e.g. `StringCastConfig(draftMode: false)` for an ad-hoc
build that goes to customers. Logging (`loggingEnabled`) still defaults to `draftMode`. Warnings (failed or
empty uploads, missing manifest) are always printed. The SDK key is public, but production clients have no
reason to create keys, which is why App Store installs are never in draft mode by default.

- **Automatic full upload (once per build):** after `start`, in the background, the SDK uploads all of your
  app's strings to `POST /v1/sdk/<id>/missing`, so the portal has every key (and your existing translations)
  after the first run, not only the keys you happened to look up:
  1. **Which bundles:** `Bundle.main`, every Swift-package resource bundle inside the app
     (`MyApp.app/<Package>_<Target>.bundle`), every embedded framework (`MyApp.app/Frameworks/*.framework`)
     and bundles one level inside them (`X.framework/Y.bundle`), plus any loaded bundle located inside the app.
     App extensions (`PlugIns/*.appex`) and system bundles are not included.
  2. **Which tables:** every `.strings` (text or compiled), `.stringsdict` and bundled `.xcstrings` in each
     `.lproj` and at the bundle root: `Localizable`, `Auth`, `Feature`… (String Catalogs are compiled by Xcode
     into `.strings` / `.stringsdict`). Not uploaded: `InfoPlist` and storyboard/XIB tables.
  3. **Base values:** per bundle, the `.lproj` matching the project's `baseLanguage`, else that bundle's
     development region, else `Base.lproj`, else unlocalized files.
  4. **Existing translations:** for every other project language, the matching `.lproj` (`es-MX.lproj`, else
     `es.lproj`; case-insensitive, `_` = `-`; `zh-Hans.lproj` or legacy `zh_CN.lproj`) is uploaded as that language.
  5. **One namespace:** keys are flat. The first occurrence wins, in this order: `Bundle.main`'s `Localizable`,
     its other tables (alphabetical), then the other bundles (alphabetical by folder name), each `Localizable`
     first. The same key with a different value elsewhere is logged at debug level and skipped.

  One language per request, batches of 500. The server creates keys that don't exist and fills values that are
  empty in that language. **It never overwrites a value**, so edits made in the portal are safe. It runs once
  per app build: the marker is `CFBundleShortVersionString|CFBundleVersion|StringCast.sdkVersion`, stored in
  `UserDefaults` per project. It is saved only after every batch succeeded **and at least one string was
  found**. If nothing is found, the SDK prints a warning listing every bundle path and table it searched, and
  tries again on the next launch. After a successful upload it prints a one-line summary (bundles, tables, keys
  per language). The upload waits for the project manifest (cached or fetched at start). If there is none
  (offline, wrong key), it warns and tries again on the next launch. Turn it off with
  `StringCastConfig(autoUploadLocalStrings: false)`.

  ```
  [StringCast] uploaded local strings for build 1.0|1|0.1.2: 2 bundle(s), 2 table(s); keys per language: en 7, es 2;
  base from StringCastDemo.app/Localizable 5, DemoFeature_DemoFeature.bundle/Feature 2; created 2, filled 2, ignored 0
  ```

  To **force a re-upload** of the same build, delete the app from the simulator/device (clears the marker), bump
  the build number, or call `uploadLocalStrings()` (below).
- **Excluding keys:** `StringCastConfig(excludedKeys: ["debug_menu_title", …])` keys are never uploaded and
  never reported as missing.
- **Missing keys:** a key you look up at runtime (through `StringCast.string`, or through any app bundle and
  table via the interception) that isn't in the base bundle, and that has a local value (the compiled string of
  that bundle/table, or `default:`), is reported to `POST /v1/sdk/<id>/missing`. Reports are debounced
  (5 s), batched (≤ 500) and sent once per key per launch. Existing keys are never overwritten.
- **Upload on demand:**

  ```swift
  let result = try await StringCast.uploadLocalStrings()   // created / filled / ignored, summed over all requests
  ```

  Same upload as the automatic one (all app bundles and tables, base values + existing translations), but it
  ignores the once-per-build marker. `uploadLocalStrings(from: someBundle)` uploads that bundle and the bundles inside it. `filled` is 0 when talking to a server that doesn't report it.

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
| `X-StringCast-SDK-Version` | `StringCast.sdkVersion`, e.g. `0.1.2` |
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

`Examples/StringCastDemo/StringCastDemo.xcodeproj` is a SwiftUI app (iOS 15+). It depends on this package and on
`Examples/StringCastDemo/DemoFeature`, a local Swift package whose `Feature` table (`en`, `es`) is read with
`NSLocalizedString(_:tableName:bundle: .module)` and `String(localized:table:bundle:)`, like a feature module of a
modular app. It is configured for `http://localhost:8787`, `p_demo` and `pk_demo_local`, and has a **QA** build
configuration (a copy of Release, so packages are compiled without `DEBUG`) to check draft mode outside Debug.

```sh
# Point StringCastDemoApp.swift at https://console.stringcast.app and your own project/SDK key, then:
open Examples/StringCastDemo/StringCastDemo.xcodeproj   # Run on an iOS Simulator
# or headless:
xcodebuild -project Examples/StringCastDemo/StringCastDemo.xcodeproj -scheme StringCastDemo -configuration QA \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/stringcast-dd build
```

## Development

```sh
swift build
swift test          # 70 XCTest cases (resolution, placeholders, decoding, plurals, engine, refresh, interception, check-in headers, auto-upload, app bundles, draft mode)
STRINGCAST_LIVE=1 swift test --filter LiveBackendTests   # read-only smoke test against localhost:8787
xcodebuild -scheme StringCast -destination 'generic/platform=iOS Simulator' build
```

If the checkout lives in an iCloud-synced folder (e.g. `~/Documents`), keep build products elsewhere, for example
`swift build --scratch-path /tmp/stringcast-spm` and `xcodebuild -derivedDataPath /tmp/stringcast-dd`. Otherwise
iCloud's extended attributes break code signing.
