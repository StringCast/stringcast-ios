import XCTest
@testable import Polyglot

final class PluralRulesTests: XCTestCase {
    private func cats(_ lang: String, _ ns: [Int]) -> [String] {
        ns.map { PluralRules.category(for: $0, language: lang).rawValue }
    }

    func testEnglishGermanSpanish() {
        XCTAssertEqual(cats("en", [0, 1, 2, 11]), ["other", "one", "other", "other"])
        XCTAssertEqual(cats("de-AT", [1, 2]), ["one", "other"])
        XCTAssertEqual(cats("es", [0, 1, 2, 1_000_000]), ["other", "one", "other", "many"])
        XCTAssertEqual(cats("it", [1, 5]), ["one", "other"])
    }

    func testFrenchAndPortuguese() {
        XCTAssertEqual(cats("fr", [0, 1, 2, 2_000_000]), ["one", "one", "other", "many"])
        XCTAssertEqual(cats("pt-BR", [0, 1, 2]), ["one", "one", "other"])
        XCTAssertEqual(cats("pt-PT", [0, 1, 2]), ["other", "one", "other"])
    }

    func testRussian() {
        XCTAssertEqual(cats("ru", [1, 2, 5, 11, 21, 22, 25, 111, 112]),
                       ["one", "few", "many", "many", "one", "few", "many", "many", "many"])
    }

    func testPolish() {
        XCTAssertEqual(cats("pl", [1, 2, 5, 12, 21, 22]), ["one", "few", "many", "many", "many", "few"])
    }

    func testArabic() {
        XCTAssertEqual(cats("ar", [0, 1, 2, 3, 10, 11, 99, 100, 102]),
                       ["zero", "one", "two", "few", "few", "many", "many", "other", "other"])
    }

    func testNoPluralLanguages() {
        XCTAssertEqual(cats("ja", [0, 1, 2]), ["other", "other", "other"])
        XCTAssertEqual(cats("zh-Hans", [1]), ["other"])
        XCTAssertEqual(cats("ko", [1]), ["other"])
    }

    func testCzechAndUnknown() {
        XCTAssertEqual(cats("cs", [1, 3, 5]), ["one", "few", "other"])
        XCTAssertEqual(cats("xx", [1, 2]), ["one", "other"])
        XCTAssertEqual(cats("en", [-1]), ["one"])
    }

    func testSelectFallsBackToOther() {
        let forms = ["one": "%d item", "other": "%d items"]
        XCTAssertEqual(PluralRules.select(forms, count: 1, language: "en"), "%d item")
        XCTAssertEqual(PluralRules.select(forms, count: 5, language: "ru"), "%d items") // "many" missing
        XCTAssertEqual(PluralRules.select(["zero": "none", "one": "a", "other": "b"], count: 0, language: "en"), "none")
        XCTAssertEqual(PluralRules.select(["one": "only"], count: 4, language: "en"), "only")
    }
}
