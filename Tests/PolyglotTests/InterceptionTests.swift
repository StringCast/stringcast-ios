import XCTest
@testable import Polyglot

final class InterceptionTests: XCTestCase {
    func testSwizzledMainBundleReturnsOTAValuesForLocalizableOnly() {
        let bundle = TranslationBundle(projectId: "p", version: 1, language: "en", strings: [
            "ota_title": .string("OTA %s"),
        ])
        let manifest = Manifest(projectId: "p", version: 1, baseLanguage: "en", languages: [.init(code: "en", url: "http://x/en.json")])
        let engine = PolyglotEngine(
            config: PolyglotConfig(projectId: "p", sdkKey: "k", draftMode: false),
            store: InMemoryBundleStore(manifest: CachedManifest(manifest: manifest), bundles: [bundle]),
            transport: MockTransport(),
            appStrings: MainBundleInterceptor.compiledString,
            preferredLanguages: { ["en"] }
        )
        Polyglot.install(engine)
        defer { Polyglot.install(nil) }
        XCTAssertTrue(MainBundleInterceptor.install())
        XCTAssertTrue(Bundle.main is PolyglotMainBundle)

        XCTAssertEqual(NSLocalizedString("ota_title", comment: ""), "OTA %@")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "ota_title", value: nil, table: "Other"), "ota_title")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "absent", value: "fallback", table: nil), "fallback")
        XCTAssertEqual(Polyglot.string("ota_title", "x"), "OTA x")
        XCTAssertNil(MainBundleInterceptor.compiledString("ota_title"))

        // Idempotent.
        XCTAssertTrue(MainBundleInterceptor.install())
    }
}
