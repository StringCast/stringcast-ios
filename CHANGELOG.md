# Changelog

## 0.1.2

- **Draft mode is decided at runtime.** `StringCastConfig.defaultDraftMode` was `#if DEBUG` inside the package, and
  Xcode compiles packages without `DEBUG` for custom configurations (QA, Staging, CI). Those builds checked in but
  never uploaded anything. It is now `true` in the Simulator, for apps with `embedded.mobileprovision`
  (development, ad-hoc, enterprise) and for TestFlight (`sandboxReceipt`), and `false` for App Store installs.
  `draftMode:` still overrides it.
- **All app bundles, all tables.** The automatic and manual upload read every `.strings` / `.stringsdict` /
  bundled `.xcstrings` table (not only `Localizable`) of `Bundle.main`, Swift-package resource bundles
  (`<Package>_<Target>.bundle`), embedded frameworks and `X.framework/Y.bundle`. `InfoPlist` and storyboard/XIB
  tables are skipped. Keys are flat. The first occurrence wins (main `Localizable`, main other tables, then other
  bundles alphabetically), and collisions are logged at debug level.
- **Interception of all app bundles.** The per-instance class swap of `Bundle.main` was replaced by a single,
  thread-safe exchange of `-[NSBundle localizedStringForKey:value:table:]`. It returns OTA values for any bundle
  inside the app and any table (so `NSLocalizedString(_:tableName:bundle: .module)` and SwiftGen accessors work).
  System bundles pass through, and the decision is cached per bundle path. `swizzleMainBundle` keeps its name and
  now controls this. Draft-mode missing-key reports work for lookups through any app bundle/table.
- **Empty uploads are never marked done.** If no strings are found, the per-build marker is not stored and a
  warning lists every bundle path and table searched (always printed). A successful upload prints a one-line
  summary (bundles, tables, keys per language). A missing manifest now also logs a warning.
- Known limitation: `String(localized:)`, `LocalizedStringResource` and SwiftUI `Text("key")` use a private
  Foundation entry point on current iOS versions and are not intercepted (their keys are still uploaded).

## 0.1.1

- **Automatic full upload in draft mode.** After `start`, once per app build (`CFBundleShortVersionString`,
  `CFBundleVersion` and SDK version), the SDK uploads every key of `Bundle.main`'s `Localizable` table
  (`.strings`, `.stringsdict`, compiled String Catalogs) as the project's base language, plus the existing
  translations of each other project language found in a matching `.lproj` (`es-MX.lproj`, else `es.lproj`;
  `zh-Hans`, legacy `zh_CN`/`zh_TW`). One language per request, batches of 500. Previously only keys looked up
  at runtime reached the portal. Waits for a manifest; the per-build marker is stored only after every batch succeeded.
- New `StringCastConfig.autoUploadLocalStrings` (default `true`, draft mode only) and `excludedKeys`
  (never uploaded or reported as missing).
- `uploadLocalStrings(from:)` now also uploads existing translations, ignores the per-build marker and returns
  counts summed over all requests.
- `UploadResult.filled`: existing keys whose empty value was filled by the server. Responses without
  `filled` (older servers) decode as 0.

## 0.1.0

- First public release: OTA strings, plurals, NSLocalizedString interception, SwiftUI helpers, draft mode, check-in headers.
