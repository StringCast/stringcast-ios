import XCTest
@testable import StringCast

final class InterceptionTests: XCTestCase {
    let manifest = Manifest(projectId: "p", version: 1, baseLanguage: "en", languages: [.init(code: "en", url: "http://x/en.json")])

    func makeEngine(_ strings: [String: TranslationValue], draftMode: Bool = false, defaults: UserDefaults = .standard) -> StringCastEngine {
        let bundle = TranslationBundle(projectId: "p", version: 1, language: "en", strings: strings)
        return StringCastEngine(
            config: StringCastConfig(projectId: "p", sdkKey: "k", draftMode: draftMode, missingKeyDebounce: 600,
                                     autoUploadLocalStrings: false),
            store: InMemoryBundleStore(manifest: CachedManifest(manifest: manifest), bundles: [bundle]),
            transport: MockTransport(),
            appStrings: BundleInterceptor.compiledString,
            preferredLanguages: { ["en"] },
            defaults: defaults
        )
    }

    override func tearDown() {
        StringCast.install(nil)
        BundleInterceptor.setAppRootForTesting(nil)
        BundleInterceptor.disable()
    }

    func testMainBundleReturnsOTAValuesForEveryTable() {
        StringCast.install(makeEngine(["ota_title": .string("OTA %s")]))
        XCTAssertTrue(BundleInterceptor.install())
        XCTAssertTrue(BundleInterceptor.install(), "idempotent")

        XCTAssertEqual(NSLocalizedString("ota_title", comment: ""), "OTA %@")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "ota_title", value: nil, table: "Other"), "OTA %@",
                       "all tables are intercepted since 0.1.2")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "absent", value: "fallback", table: nil), "fallback")
        XCTAssertEqual(StringCast.string("ota_title", "x"), "OTA x")
        XCTAssertNil(BundleInterceptor.compiledString("ota_title"), "SDK fallbacks call the original implementation")

        BundleInterceptor.disable()
        XCTAssertEqual(NSLocalizedString("ota_title", comment: ""), "ota_title", "disabled = pass-through")
    }

    func testPackageBundleAndCustomTableInsideAppAreIntercepted() throws {
        let app = try FixtureBundle.app()
        let feature = try app.nested("Feature_Feature.bundle")
        try feature.table("en", "Feature", ["feature_title": "Local title", "only_local": "Local only", "items": "%d items"])
        try feature.storyboardTable("en")
        try feature.table("en", "InfoPlist", ["feature_title": "Info"])
        let kit = try app.nested("Frameworks/Kit.framework")
        try kit.table("en", "Kit", ["feature_title": "Kit local"])

        let outside = try FixtureBundle()
        try outside.table("en", "Feature", ["feature_title": "Outside local"])

        StringCast.install(makeEngine([
            "feature_title": .string("OTA title %s"),
            "items": .plural(["one": "%d item (OTA)", "other": "%d items (OTA)"]),
            "8Fh-2k-3dx.text": .string("OTA storyboard"),
        ]))
        BundleInterceptor.setAppRootForTesting(app.url.path)
        XCTAssertTrue(BundleInterceptor.install())

        let fb = feature.bundle
        XCTAssertTrue(BundleInterceptor.info(for: fb).isApp)
        XCTAssertFalse(BundleInterceptor.info(for: outside.bundle).isApp)

        XCTAssertEqual(NSLocalizedString("feature_title", tableName: "Feature", bundle: fb, comment: ""), "OTA title %@")
        XCTAssertEqual(fb.localizedString(forKey: "feature_title", value: nil, table: "Feature"), "OTA title %@")
        XCTAssertEqual(kit.bundle.localizedString(forKey: "feature_title", value: nil, table: "Kit"), "OTA title %@",
                       "embedded framework")
        XCTAssertEqual(fb.localizedString(forKey: "only_local", value: nil, table: "Feature"), "Local only")
        XCTAssertEqual(fb.localizedString(forKey: "items", value: nil, table: "Feature"), "%d items",
                       "plural OTA values keep the compiled value")
        XCTAssertEqual(fb.localizedString(forKey: "8Fh-2k-3dx.text", value: nil, table: "Main"), "Nope",
                       "storyboard tables pass through")
        XCTAssertEqual(fb.localizedString(forKey: "feature_title", value: nil, table: "InfoPlist"), "Info",
                       "InfoPlist passes through")

        // Bundles outside the app are never touched.
        XCTAssertEqual(outside.bundle.localizedString(forKey: "feature_title", value: nil, table: "Feature"), "Outside local")
        // The original implementation is reachable without recursion.
        XCTAssertEqual(BundleInterceptor.original(fb, key: "feature_title", value: nil, table: "Feature"), "Local title")
    }

    func testMissingKeysAreReportedFromAnyAppBundleAndTable() throws {
        let app = try FixtureBundle.app()
        let feature = try app.nested("Frameworks/Kit.framework/Feature.bundle")
        try feature.table("en", "Auth", ["auth_new": "Sign in", "auth_known": "Known"])
        let engine = makeEngine(["auth_known": .string("Known OTA")], draftMode: true)
        StringCast.install(engine)
        BundleInterceptor.setAppRootForTesting(app.url.path)
        BundleInterceptor.install()

        XCTAssertEqual(feature.bundle.localizedString(forKey: "auth_new", value: nil, table: "Auth"), "Sign in")
        XCTAssertEqual(feature.bundle.localizedString(forKey: "auth_known", value: nil, table: "Auth"), "Known OTA")
        XCTAssertEqual(engine.reporter?.pendingKeys, ["auth_new"])
    }
}
