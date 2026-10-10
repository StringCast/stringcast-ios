import XCTest
@testable import StringCast

/// Builds a throwaway directory-backed `Bundle` with `.lproj` folders (unique path per call, so
/// `Bundle`'s per-path caching never leaks between tests).
final class FixtureBundle {
    let url: URL
    private let owned: Bool

    init(developmentRegion: String? = "en", version: String = "1.2", build: String = "34") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StringCastFixture-\(UUID().uuidString).bundle", isDirectory: true)
        owned = true
        try Self.create(url, developmentRegion: developmentRegion, version: version, build: build)
    }

    /// A bundle at a given location (e.g. inside another fixture). Removed only with its owner.
    init(at url: URL, developmentRegion: String? = "en", owned: Bool = false, infoPlist: Bool = true) throws {
        self.url = url
        self.owned = owned
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if infoPlist { try Self.create(url, developmentRegion: developmentRegion, version: "1.0", build: "1") }
    }

    /// A temp directory holding `<name>` (e.g. `Demo.app`), so the app folder keeps a realistic name.
    static func app(_ name: String = "Demo.app", version: String = "1.0", build: String = "1") throws -> FixtureBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StringCastApp-\(UUID().uuidString)", isDirectory: true)
        let f = try FixtureBundle(at: dir.appendingPathComponent(name, isDirectory: true), owned: true)
        try create(f.url, developmentRegion: "en", version: version, build: build)
        f.cleanup = dir
        return f
    }

    private var cleanup: URL?

    private static func create(_ url: URL, developmentRegion: String?, version: String, build: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "app.stringcast.fixture",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": build]
        if let dev = developmentRegion { info["CFBundleDevelopmentRegion"] = dev }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
    }

    deinit {
        guard owned else { return }
        try? FileManager.default.removeItem(at: cleanup ?? url)
    }

    /// A child bundle at `relativePath` (e.g. `Frameworks/Kit.framework`).
    func nested(_ relativePath: String, developmentRegion: String? = "en", infoPlist: Bool = true) throws -> FixtureBundle {
        try FixtureBundle(at: url.appendingPathComponent(relativePath, isDirectory: true),
                          developmentRegion: developmentRegion, infoPlist: infoPlist)
    }

    var bundle: Bundle { Bundle(url: url)! }

    private func dir(_ lproj: String?) throws -> URL {
        guard let lproj = lproj else { return url }
        let d = url.appendingPathComponent("\(lproj).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Text `.strings` file for any table (`lproj` nil = unlocalized, at the bundle root).
    func table(_ lproj: String?, _ name: String, _ values: [String: String]) throws {
        let text = values.sorted { $0.key < $1.key }
            .map { "\"\(escape($0.key))\" = \"\(escape($0.value))\";" }.joined(separator: "\n")
        try Data(text.utf8).write(to: dir(lproj).appendingPathComponent("\(name).strings"))
    }

    /// A compiled storyboard (`Base.lproj/<name>.storyboardc`) — its tables are UI tables.
    func storyboard(_ name: String, lproj: String? = "Base") throws {
        try FileManager.default.createDirectory(at: dir(lproj).appendingPathComponent("\(name).storyboardc"),
                                                withIntermediateDirectories: true)
    }

    /// Text `.strings` (what Xcode copies when `STRINGS_FILE_OUTPUT_ENCODING` is UTF-8).
    func strings(_ lproj: String, _ values: [String: String]) throws {
        let text = values.sorted { $0.key < $1.key }
            .map { "\"\(escape($0.key))\" = \"\(escape($0.value))\";" }.joined(separator: "\n")
        try Data(text.utf8).write(to: dir(lproj).appendingPathComponent("Localizable.strings"))
    }

    /// Compiled binary-plist `.strings` (Xcode's default output for app builds).
    func binaryStrings(_ lproj: String, _ values: [String: String]) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            .write(to: dir(lproj).appendingPathComponent("Localizable.strings"))
    }

    func stringsDict(_ lproj: String, key: String, one: String, other: String) throws {
        let dict: [String: Any] = [key: [
            "NSStringLocalizedFormatKey": "%#@n@",
            "n": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d",
                  "one": one, "other": other],
        ]]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            .write(to: dir(lproj).appendingPathComponent("Localizable.stringsdict"))
    }

    /// A storyboard table (`Main.strings` next to `Base.lproj/Main.storyboardc`): never uploaded.
    func storyboardTable(_ lproj: String) throws {
        try storyboard("Main")
        try Data("\"8Fh-2k-3dx.text\" = \"Nope\";".utf8).write(to: dir(lproj).appendingPathComponent("Main.strings"))
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Records `/missing` payloads; `fail(language)` makes requests for that language return 500.
final class MissingRecorder {
    struct Request { var language: String; var platform: String; var keys: [String: Any] }
    private let lock = NSLock()
    private(set) var requests: [Request] = []
    var failingLanguages: Set<String> = []
    var includeFilled = true

    func install(on transport: MockTransport) {
        transport.handlers["/v1/sdk/p/missing"] = { [unowned self] req in
            let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            let language = body["language"] as? String ?? ""
            var keys: [String: Any] = [:]
            for k in body["keys"] as? [[String: Any]] ?? [] { keys[k["key"] as? String ?? ""] = k["value"] }
            let failing = lock.locked { () -> Bool in
                requests.append(Request(language: language, platform: body["platform"] as? String ?? "", keys: keys))
                return failingLanguages.contains(language)
            }
            if failing { return (500, [:], Data("boom".utf8)) }
            let json = includeFilled
                ? #"{"created":\#(keys.count),"filled":1,"ignored":0}"#
                : #"{"created":\#(keys.count),"ignored":0}"#
            return (200, [:], Data(json.utf8))
        }
    }

    var snapshot: [Request] { lock.locked { requests } }
}

final class AutoUploadTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        suite = "StringCastTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func manifest(base: String = "en", languages: [String]) -> CachedManifest {
        CachedManifest(manifest: Manifest(projectId: "p", version: 0, baseLanguage: base, languages: languages.map {
            .init(code: $0, url: "http://localhost:8787/v1/sdk/p/bundles/0/\($0).json")
        }), etag: "\"v0\"", lastCheck: Date())
    }

    func makeEngine(bundle: Bundle, transport: MockTransport, manifest: CachedManifest?,
                    draftMode: Bool = true, auto: Bool = true, excluded: Set<String> = []) -> StringCastEngine {
        let config = StringCastConfig(projectId: "p", sdkKey: "pk_test", baseURL: URL(string: "http://localhost:8787")!,
                                      draftMode: draftMode, missingKeyDebounce: 0.05,
                                      autoUploadLocalStrings: auto, excludedKeys: excluded)
        return StringCastEngine(config: config, store: InMemoryBundleStore(manifest: manifest), transport: transport,
                                appStrings: { _ in nil }, preferredLanguages: { ["en"] },
                                localBundle: bundle, defaults: defaults)
    }

    // MARK: lproj matching

    func testLprojMatching() {
        let names = ["Base", "en", "es", "es-MX", "pt-BR", "zh-Hans", "zh_TW"]
        XCTAssertEqual(LocalStringsReader.matchLproj("es-MX", in: names), "es-MX")       // exact
        XCTAssertEqual(LocalStringsReader.matchLproj("es-AR", in: names), "es")          // language fallback
        XCTAssertEqual(LocalStringsReader.matchLproj("ES_mx", in: names), "es-MX")       // case / underscore
        XCTAssertEqual(LocalStringsReader.matchLproj("zh-Hans", in: names), "zh-Hans")
        XCTAssertEqual(LocalStringsReader.matchLproj("zh-Hans-CN", in: names), "zh-Hans") // script
        XCTAssertEqual(LocalStringsReader.matchLproj("zh-Hant", in: names), "zh_TW")     // legacy alias
        XCTAssertNil(LocalStringsReader.matchLproj("pt", in: names), "no reverse fallback pt → pt-BR")
        XCTAssertNil(LocalStringsReader.matchLproj("fr", in: names))
        XCTAssertNil(LocalStringsReader.matchLproj("base", in: names), "Base.lproj is never a language")
        XCTAssertEqual(LocalStringsReader.matchLproj("zh-Hans", in: ["zh_CN"]), "zh_CN")
    }

    func testCollectBaseAndTranslations() throws {
        let f = try FixtureBundle()
        try f.strings("en", ["hello": "Hello", "bye": "Bye"])
        try f.stringsDict("en", key: "items", one: "%d item", other: "%d items")
        try f.binaryStrings("es", ["hello": "Hola", "empty": ""])
        try f.stringsDict("es", key: "items", one: "%d artículo", other: "%d artículos")
        try f.strings("zh-Hans", ["hello": "你好"])
        try f.strings("de", ["hello": "Hallo"])   // not a project language
        try f.storyboardTable("en")
        try f.table("en", "InfoPlist", ["CFBundleDisplayName": "Nope"])

        let units = LocalStringsReader.collect(bundle: f.bundle, baseLanguage: "en",
                                               languages: ["en", "es-MX", "zh-Hans", "fr", "en-GB"])
        XCTAssertEqual(units.map(\.language), ["en", "es-MX", "zh-Hans"])
        XCTAssertEqual(units[0].source, "en")
        XCTAssertEqual(units[0].entries, [
            "hello": .string("Hello"), "bye": .string("Bye"),
            "items": .plural(["one": "%d item", "other": "%d items"]),
        ])
        XCTAssertEqual(units[1].source, "es")
        XCTAssertEqual(units[1].entries, [
            "hello": .string("Hola"), "items": .plural(["one": "%d artículo", "other": "%d artículos"]),
        ], "empty values are not sent as translations")
        XCTAssertEqual(units[2].entries, ["hello": .string("你好")])
    }

    func testCollectUsesDevelopmentRegionWhenBaseLprojMissing() throws {
        let f = try FixtureBundle(developmentRegion: "en")
        try f.strings("en", ["hello": "Hello"])
        try f.strings("es", ["hello": "Hola"])
        let units = LocalStringsReader.collect(bundle: f.bundle, baseLanguage: "en-US", languages: ["en-US", "es"])
        // `en-US` → `en.lproj` via language fallback.
        XCTAssertEqual(units.map(\.language), ["en-US", "es"])
        XCTAssertEqual(units[0].entries, ["hello": .string("Hello")])
    }

    // MARK: Automatic upload

    func testAutoUploadBatchesPerLanguageAndStoresMarker() async throws {
        let f = try FixtureBundle(version: "2.0", build: "7")
        var base: [String: String] = [:]
        for i in 0..<1203 { base[String(format: "key_%04d", i)] = "Value \(i)" }
        try f.binaryStrings("en", base)
        try f.strings("es", ["key_0000": "Valor 0", "key_0001": "Valor 1"])

        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.install(on: transport)
        let engine = makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en", "es-MX"]))
        await engine.autoUploadIfNeeded()

        let reqs = recorder.snapshot
        XCTAssertEqual(reqs.map(\.language), ["en", "en", "en", "es-MX"])
        XCTAssertEqual(reqs.map(\.keys.count), [500, 500, 203, 2])
        XCTAssertTrue(reqs.allSatisfy { $0.platform == "ios" })
        XCTAssertEqual(reqs[3].keys["key_0001"] as? String, "Valor 1")
        XCTAssertEqual(Set(reqs.prefix(3).flatMap(\.keys.keys)).count, 1203)
        XCTAssertEqual(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"), "2.0|7|\(StringCast.sdkVersion)")

        // Next launch of the same build: skipped.
        let again = makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en", "es-MX"]))
        await again.autoUploadIfNeeded()
        XCTAssertEqual(recorder.snapshot.count, 4)

        // New build number: uploads again.
        let f2 = try FixtureBundle(version: "2.0", build: "8")
        try f2.strings("en", ["a": "A"])
        let next = makeEngine(bundle: f2.bundle, transport: transport, manifest: manifest(languages: ["en"]))
        await next.autoUploadIfNeeded()
        XCTAssertEqual(recorder.snapshot.count, 5)
        XCTAssertEqual(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"), "2.0|8|\(StringCast.sdkVersion)")
    }

    func testMarkerNotStoredWhenABatchFails() async throws {
        let f = try FixtureBundle()
        try f.strings("en", ["hello": "Hello"])
        try f.strings("es", ["hello": "Hola"])
        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.failingLanguages = ["es"]
        recorder.install(on: transport)
        await makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en", "es"])).autoUploadIfNeeded()
        XCTAssertEqual(recorder.snapshot.map(\.language), ["en", "es"])
        XCTAssertNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"))

        // Next launch retries everything and stores the marker.
        recorder.failingLanguages = []
        await makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en", "es"])).autoUploadIfNeeded()
        XCTAssertEqual(recorder.snapshot.map(\.language), ["en", "es", "en", "es"])
        XCTAssertNotNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"))
    }

    func testAutoUploadWaitsForManifest() async throws {
        let f = try FixtureBundle()
        try f.strings("en", ["hello": "Hello"])
        let transport = MockTransport()   // manifest fetch → 404
        let recorder = MissingRecorder()
        recorder.install(on: transport)
        let engine = makeEngine(bundle: f.bundle, transport: transport, manifest: nil)
        await engine.refresh(force: false)
        await engine.autoUploadIfNeeded()
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"))
    }

    func testAutoUploadOnlyInDraftModeAndWhenEnabled() async throws {
        let f = try FixtureBundle()
        try f.strings("en", ["hello": "Hello"])
        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.install(on: transport)
        await makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en"]), draftMode: false).autoUploadIfNeeded()
        await makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en"]), auto: false).autoUploadIfNeeded()
        XCTAssertTrue(recorder.snapshot.isEmpty)
    }

    // MARK: Manual upload, counts, exclusions

    func testManualUploadIgnoresMarkerAndSumsCounts() async throws {
        let f = try FixtureBundle()
        try f.strings("en", ["a": "A", "b": "B", "internal_debug": "x"])
        try f.strings("es", ["a": "A es"])
        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.install(on: transport)
        let engine = makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en", "es"]),
                                excluded: ["internal_debug"])
        defaults.set(StringCastEngine.buildMarker(for: f.bundle), forKey: engine.autoUploadMarkerKey)

        let r = try await engine.uploadLocalStrings(bundle: f.bundle)
        XCTAssertEqual(r, UploadResult(created: 3, filled: 2, ignored: 0))
        XCTAssertEqual(recorder.snapshot.map(\.language), ["en", "es"])
        XCTAssertNil(recorder.snapshot[0].keys["internal_debug"], "excludedKeys are never uploaded")

        // Public entry point goes through the same path.
        StringCast.install(engine)
        defer { StringCast.install(nil) }
        let r2 = try await StringCast.uploadLocalStrings(from: f.bundle)
        XCTAssertEqual(r2.created, 3)
        XCTAssertEqual(recorder.snapshot.count, 4)
    }

    func testManualUploadToleratesOldServerResponse() async throws {
        let f = try FixtureBundle()
        try f.strings("en", ["a": "A"])
        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.includeFilled = false
        recorder.install(on: transport)
        let engine = makeEngine(bundle: f.bundle, transport: transport, manifest: manifest(languages: ["en"]))
        let r = try await engine.uploadLocalStrings(bundle: f.bundle)
        XCTAssertEqual(r, UploadResult(created: 1, ignored: 0))
        XCTAssertEqual(r.filled, 0)
    }

    func testUploadResultDecoding() throws {
        let d = JSONDecoder()
        XCTAssertEqual(try d.decode(UploadResult.self, from: Data(#"{"created":2,"filled":3,"ignored":4}"#.utf8)),
                       UploadResult(created: 2, filled: 3, ignored: 4))
        XCTAssertEqual(try d.decode(UploadResult.self, from: Data(#"{"created":2,"ignored":4}"#.utf8)),
                       UploadResult(created: 2, filled: 0, ignored: 4))
        XCTAssertEqual(try d.decode(UploadResult.self, from: Data("{}".utf8)), UploadResult(created: 0, ignored: 0))
    }

    func testExcludedKeysAreNotReportedAsMissing() {
        let config = StringCastConfig(projectId: "p", sdkKey: "pk_test", baseURL: URL(string: "http://localhost:8787")!,
                                      draftMode: true, missingKeyDebounce: 60, autoUploadLocalStrings: false,
                                      excludedKeys: ["debug_only"])
        let engine = StringCastEngine(config: config, store: InMemoryBundleStore(manifest: manifest(languages: ["en"])),
                                      transport: MockTransport(),
                                      appStrings: { ["debug_only": "D", "real": "R"][$0] },
                                      preferredLanguages: { ["en"] }, localBundle: .main, defaults: defaults)
        _ = engine.string("debug_only", defaultValue: nil, args: [])
        _ = engine.string("real", defaultValue: nil, args: [])
        XCTAssertEqual(engine.reporter?.pendingKeys, ["real"])
    }
}
