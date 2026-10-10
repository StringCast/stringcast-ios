import XCTest
@testable import StringCast

final class DraftModeTests: XCTestCase {
    func testDraftModeHeuristic() {
        typealias Env = DraftModeDetector.Environment
        XCTAssertTrue(DraftModeDetector.isDraftMode(Env(isSimulator: true, hasEmbeddedProvisioningProfile: false, receiptName: nil)))
        XCTAssertTrue(DraftModeDetector.isDraftMode(Env(isSimulator: false, hasEmbeddedProvisioningProfile: true, receiptName: nil)),
                      "development / ad-hoc / enterprise")
        XCTAssertTrue(DraftModeDetector.isDraftMode(Env(isSimulator: false, hasEmbeddedProvisioningProfile: false, receiptName: "sandboxReceipt")),
                      "TestFlight")
        XCTAssertFalse(DraftModeDetector.isDraftMode(Env(isSimulator: false, hasEmbeddedProvisioningProfile: false, receiptName: "receipt")),
                       "App Store")
        XCTAssertFalse(DraftModeDetector.isDraftMode(Env(isSimulator: false, hasEmbeddedProvisioningProfile: false, receiptName: nil)))
    }

    func testDefaultDraftModeMatchesCurrentEnvironment() {
        XCTAssertEqual(StringCastConfig.defaultDraftMode, DraftModeDetector.isDraftMode(.current))
        XCTAssertEqual(DraftModeDetector.Environment.current.isSimulator, DraftModeDetector.isSimulatorBuild)
        XCTAssertFalse(StringCastConfig(projectId: "p", sdkKey: "k", draftMode: false).draftMode, "explicit override wins")
    }
}

final class AppBundlesTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        suite = "StringCastTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func manifest(languages: [String]) -> CachedManifest {
        CachedManifest(manifest: Manifest(projectId: "p", version: 0, baseLanguage: "en", languages: languages.map {
            .init(code: $0, url: "http://localhost:8787/v1/sdk/p/bundles/0/\($0).json")
        }), etag: "\"v0\"", lastCheck: Date())
    }

    func makeEngine(bundle: Bundle, transport: MockTransport, languages: [String] = ["en", "es"],
                    excluded: Set<String> = []) -> StringCastEngine {
        let config = StringCastConfig(projectId: "p", sdkKey: "pk_test", baseURL: URL(string: "http://localhost:8787")!,
                                      draftMode: true, missingKeyDebounce: 600, excludedKeys: excluded)
        return StringCastEngine(config: config, store: InMemoryBundleStore(manifest: manifest(languages: languages)),
                                transport: transport, appStrings: { _ in nil }, preferredLanguages: { ["en"] },
                                localBundle: bundle, defaults: defaults)
    }

    // MARK: Discovery

    func testNestedBundleDiscovery() throws {
        let app = try FixtureBundle.app("Sailor.app")
        _ = try app.nested("Zeta_Feature.bundle")
        _ = try app.nested("Auth_Auth.bundle", infoPlist: false)          // SPM bundles may lack Info.plist on disk
        _ = try app.nested("Frameworks/Kit.framework")
        _ = try app.nested("Frameworks/Kit.framework/KitResources.bundle")
        _ = try app.nested("Frameworks/Kit.framework/KitResources.bundle/TooDeep.bundle")
        _ = try app.nested("Frameworks/Loose.bundle")
        _ = try app.nested("StringCast_StringCast.bundle")                 // the SDK's own bundle
        _ = try app.nested("PlugIns/Widget.appex")                         // extensions are separate processes
        try FileManager.default.createDirectory(at: app.url.appendingPathComponent("NotABundle.lproj"), withIntermediateDirectories: true)
        let outside = try FixtureBundle()
        let insideLoaded = Bundle(url: app.url.appendingPathComponent("Frameworks/Kit.framework"))!

        let bundles = AppBundles.discover(root: app.bundle, loaded: [outside.bundle, insideLoaded, .main])
        XCTAssertEqual(bundles.map(\.bundleURL.lastPathComponent),
                       ["Sailor.app", "Auth_Auth.bundle", "Kit.framework", "KitResources.bundle", "Loose.bundle", "Zeta_Feature.bundle"])
        XCTAssertEqual(Set(bundles.map { AppBundles.canonicalPath($0.bundlePath) }).count, bundles.count, "deduplicated")
    }

    func testCanonicalPathAndContainment() {
        XCTAssertTrue(AppBundles.isInside("/a/App.app/Frameworks/K.framework", root: "/a/App.app"))
        XCTAssertTrue(AppBundles.isInside("/a/App.app", root: "/a/App.app"))
        XCTAssertFalse(AppBundles.isInside("/a/App.appendix/x", root: "/a/App.app"))
        XCTAssertEqual(AppBundles.canonicalPath("/tmp/x/../y/"), AppBundles.canonicalPath("/tmp/y"))
    }

    // MARK: Collection

    func testMultiBundleMultiTableCollectionWithPrecedence() throws {
        let app = try FixtureBundle.app()
        try app.table("en", "Localizable", ["welcome": "Welcome", "shared": "main Localizable", "same": "Same"])
        try app.table("en", "Auth", ["auth_title": "Sign in", "shared": "main Auth", "same": "Same"])
        try app.table("en", "Billing", ["billing_title": "Billing", "auth_title": "Billing's sign in"])
        try app.table("es", "Localizable", ["welcome": "Bienvenido"])
        try app.table("es", "Auth", ["auth_title": "Entrar"])
        try app.storyboardTable("es")
        try app.table("en", "InfoPlist", ["NSCameraUsageDescription": "Camera"])
        try app.table(nil, "Unlocalized", ["unlocalized_key": "Root value"])

        let feature = try app.nested("Feature_Feature.bundle")
        try feature.table("en", "Feature", ["feature_title": "Feature", "shared": "feature", "welcome": "Welcome"])
        try feature.table("es", "Feature", ["feature_title": "Función", "welcome": "Hola"])
        try feature.stringsDict("en", key: "feature_items", one: "%d thing", other: "%d things")

        let kit = try app.nested("Frameworks/Kit.framework")
        try kit.table("en", "Kit", ["kit_key": "Kit", "shared": "kit"])

        let bundles = AppBundles.discover(root: app.bundle, loaded: [])
        let c = LocalStringsReader.collect(bundles: bundles, baseLanguage: "en", languages: ["en", "es", "fr"])

        XCTAssertEqual(c.scanned.map(\.name), ["Demo.app", "Feature_Feature.bundle", "Kit.framework"])
        XCTAssertEqual(c.scanned[0].tables, ["Localizable", "Auth", "Billing", "Unlocalized"], "no InfoPlist, no storyboard table")
        XCTAssertEqual(c.units.map(\.language), ["en", "es"])
        XCTAssertEqual(c.units[0].entries, [
            "welcome": .string("Welcome"),
            "shared": .string("main Localizable"),         // main Localizable beats every other table
            "same": .string("Same"),
            "auth_title": .string("Sign in"),               // Auth < Billing alphabetically
            "billing_title": .string("Billing"),
            "unlocalized_key": .string("Root value"),
            "feature_title": .string("Feature"),
            "feature_items": .plural(["one": "%d thing", "other": "%d things"]),
            "kit_key": .string("Kit"),
        ])
        XCTAssertEqual(c.units[0].origins.map { "\($0.bundle)/\($0.table) \($0.count)" }, [
            "Demo.app/Localizable 3", "Demo.app/Auth 1", "Demo.app/Billing 1", "Demo.app/Unlocalized 1",
            "Feature_Feature.bundle/Localizable 1", "Feature_Feature.bundle/Feature 1", "Kit.framework/Kit 1",
        ])
        XCTAssertEqual(c.units[1].entries, [
            "welcome": .string("Bienvenido"), "auth_title": .string("Entrar"), "feature_title": .string("Función"),
        ], "translations follow the same precedence (main es beats Feature es)")
        XCTAssertEqual(c.units[1].source, "es")

        // Collisions with a different value are recorded; identical values are not.
        let collisions = c.collisions.map { "\($0.language):\($0.key):\($0.kept)>\($0.ignored)" }
        XCTAssertEqual(Set(collisions), [
            "en:shared:Demo.app/Localizable>Demo.app/Auth",
            "en:auth_title:Demo.app/Auth>Demo.app/Billing",
            "en:shared:Demo.app/Localizable>Feature_Feature.bundle/Feature",
            "en:shared:Demo.app/Localizable>Kit.framework/Kit",
            "es:welcome:Demo.app/Localizable>Feature_Feature.bundle/Feature",
        ])
    }

    func testUploadsAllAppBundlesAndRespectsExcludedKeys() async throws {
        let app = try FixtureBundle.app(version: "3.1", build: "99")
        try app.table("en", "Localizable", ["welcome": "Welcome", "debug_menu": "Debug"])
        let feature = try app.nested("DemoFeature_DemoFeature.bundle")
        try feature.table("en", "Feature", ["feature_title": "Feature title", "feature_body": "Body"])
        try feature.table("es", "Feature", ["feature_title": "Título"])

        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.install(on: transport)
        await makeEngine(bundle: app.bundle, transport: transport, excluded: ["debug_menu", "feature_body"]).autoUploadIfNeeded()

        let reqs = recorder.snapshot
        XCTAssertEqual(reqs.map(\.language), ["en", "es"])
        XCTAssertEqual(Set(reqs[0].keys.keys), ["welcome", "feature_title"])
        XCTAssertEqual(reqs[1].keys["feature_title"] as? String, "Título")
        XCTAssertEqual(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"), "3.1|99|\(StringCast.sdkVersion)")
    }

    // MARK: Empty runs

    func testEmptyResultDoesNotStoreMarker() async throws {
        let app = try FixtureBundle.app()
        try app.storyboardTable("en")                                   // only non-uploadable tables
        try app.table("en", "InfoPlist", ["CFBundleDisplayName": "Demo"])
        let transport = MockTransport()
        let recorder = MissingRecorder()
        recorder.install(on: transport)

        let engine = makeEngine(bundle: app.bundle, transport: transport)
        let collection = engine.collectLocalStrings(root: app.bundle)
        XCTAssertTrue(collection.isEmpty)
        let message = StringCastEngine.emptyCollectionMessage(collection, marker: "1.0|1|x")
        XCTAssertTrue(message.contains(app.bundle.bundlePath), message)
        XCTAssertTrue(message.contains("no tables"), message)

        await engine.autoUploadIfNeeded()
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"), "an empty run is never marked done")

        // Excluded keys only = empty too.
        try app.table("en", "Localizable", ["debug_only": "x"])
        await makeEngine(bundle: app.bundle, transport: transport, excluded: ["debug_only"]).autoUploadIfNeeded()
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"))

        // Strings appear in a later build of the same version (e.g. resources fixed): the next launch uploads.
        try app.table("en", "Localizable", ["hello": "Hello"])
        await makeEngine(bundle: app.bundle, transport: transport).autoUploadIfNeeded()
        XCTAssertEqual(recorder.snapshot.map(\.language), ["en"])
        XCTAssertNotNil(defaults.string(forKey: "app.stringcast.p.autoUploadMarker"))
    }

    func testUploadSummaryMentionsBundlesTablesAndCounts() throws {
        let app = try FixtureBundle.app()
        try app.table("en", "Localizable", ["a": "A"])
        let feature = try app.nested("F_F.bundle")
        try feature.table("en", "Feature", ["b": "B"])
        let engine = makeEngine(bundle: app.bundle, transport: MockTransport())
        let s = StringCastEngine.uploadSummary(engine.collectLocalStrings(root: app.bundle),
                                               result: UploadResult(created: 2, filled: 0, ignored: 0), marker: "m")
        XCTAssertTrue(s.contains("2 bundle(s), 2 table(s)"), s)
        XCTAssertTrue(s.contains("Demo.app/Localizable 1, F_F.bundle/Feature 1"), s)
        XCTAssertTrue(s.contains("en 2"), s)
    }
}
