import XCTest
@testable import StringCast

final class LanguageResolverTests: XCTestCase {
    let project = ["en", "es", "es-MX", "pt-BR", "zh-Hans", "zh-Hant", "fr"]

    func testExactMatchIsCaseInsensitiveAndUnderscoreNormalised() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["es_mx"], available: project, baseLanguage: "en"), "es-MX")
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["PT-br"], available: project, baseLanguage: "en"), "pt-BR")
    }

    func testLanguageWithScript() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["zh-Hant-TW"], available: project, baseLanguage: "en"), "zh-Hant")
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["zh-Hans-CN"], available: project, baseLanguage: "en"), "zh-Hans")
    }

    func testLanguageOnly() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["es-AR"], available: project, baseLanguage: "en"), "es")
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["fr-CA"], available: project, baseLanguage: "en"), "fr")
    }

    func testAnyProjectLanguageWithSameLanguageSubtag() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["pt-PT"], available: project, baseLanguage: "en"), "pt-BR")
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["zh"], available: project, baseLanguage: "en"), "zh-Hans")
    }

    func testPreferenceOrderFirstHitWins() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["de-DE", "fr-FR", "es"], available: project, baseLanguage: "en"), "fr")
    }

    func testFallbackToBase() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["de-DE", "ja-JP"], available: project, baseLanguage: "en"), "en")
        XCTAssertEqual(LanguageResolver.resolve(preferred: [], available: [], baseLanguage: "en"), "en")
    }

    func testOverrideBeatsAll() {
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["fr"], available: project, baseLanguage: "en", override: "es_mx"), "es-MX")
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["fr"], available: project, baseLanguage: "en", override: "pt"), "pt-BR")
        // Unknown override is kept as given (lookups then fall back to base bundle).
        XCTAssertEqual(LanguageResolver.resolve(preferred: ["fr"], available: project, baseLanguage: "en", override: "de_AT"), "de-AT")
    }

    func testDoesNotMatchPrefixOfDifferentLanguage() {
        // "e" must not match "en"/"es"; "es" must not match "est".
        XCTAssertNil(LanguageResolver.match("e", in: ["en", "es"]))
        XCTAssertNil(LanguageResolver.match("es", in: ["est"]))
    }
}
