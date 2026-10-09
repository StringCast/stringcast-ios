# Releasing the StringCast iOS SDK

Swift Package Manager resolves versions straight from git tags — there is no registry upload.

1. Bump `StringCast.sdkVersion` in `Sources/StringCast/CheckInHeaders.swift` (sent as `X-StringCast-SDK-Version`).
2. Update `CHANGELOG.md`.
3. From the StringCast monorepo run `scripts/release-sdk.sh ios <version>` — it mirrors `sdk-ios/` to
   `github.com/stringcast/stringcast-ios` and pushes the tag `<version>` (plain semver, e.g. `0.1.0`, no `v`).
4. Apps pick it up with *File › Packages › Update to Latest Package Versions*.

Never move or delete a published tag: SwiftPM caches resolved revisions and a moved tag breaks builds.
