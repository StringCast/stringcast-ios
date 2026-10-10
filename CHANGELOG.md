# Changelog

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
