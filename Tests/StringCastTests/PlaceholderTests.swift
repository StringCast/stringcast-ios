import XCTest
@testable import StringCast

final class PlaceholderTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(PlaceholderFormatter.normalize("Hello %s"), "Hello %@")
        XCTAssertEqual(PlaceholderFormatter.normalize("%1$s and %2$s"), "%1$@ and %2$@")
        XCTAssertEqual(PlaceholderFormatter.normalize("%-10s|"), "%-10@|")
        XCTAssertEqual(PlaceholderFormatter.normalize("100%% sure %d"), "100%% sure %d")
        XCTAssertEqual(PlaceholderFormatter.normalize("%%s literal"), "%%s literal")
        XCTAssertEqual(PlaceholderFormatter.normalize("%@ %d %1$@ %.2f"), "%@ %d %1$@ %.2f")
        XCTAssertEqual(PlaceholderFormatter.normalize("no placeholders"), "no placeholders")
        XCTAssertEqual(PlaceholderFormatter.normalize("trailing %"), "trailing %")
        XCTAssertEqual(PlaceholderFormatter.normalize("Hola %s, ¿%d €?"), "Hola %@, ¿%d €?")
    }

    func testFormatAfterNormalisation() {
        XCTAssertEqual(PlaceholderFormatter.format("Hello %s", args: ["Ana"]), "Hello Ana")
        XCTAssertEqual(PlaceholderFormatter.format("%2$s, %1$s", args: ["A", "B"]), "B, A")
        XCTAssertEqual(PlaceholderFormatter.format("%d items", args: [3]), "3 items")
        XCTAssertEqual(PlaceholderFormatter.format("%ld of %lu", args: [1, UInt(2)]), "1 of 2")
        XCTAssertEqual(PlaceholderFormatter.format("%.1f%%", args: [12.34]), "12.3%")
    }

    func testNoArgsReturnsNormalisedTemplate() {
        XCTAssertEqual(PlaceholderFormatter.format("Hi %s", args: []), "Hi %@")
    }

    func testUnsafeFormatsAreRejectedInsteadOfCrashing() {
        // Translator turned %d into %@: would dereference an Int.
        XCTAssertNil(PlaceholderFormatter.format("%@ items", args: [3]))
        // Too few arguments.
        XCTAssertNil(PlaceholderFormatter.format("%@ and %@", args: ["a"]))
        XCTAssertNil(PlaceholderFormatter.format("%3$@", args: ["a", "b"]))
        // String passed for %d.
        XCTAssertNil(PlaceholderFormatter.format("%d", args: ["x"]))
        // Extra arguments are fine.
        XCTAssertEqual(PlaceholderFormatter.format("plain", args: ["x"]), "plain")
    }

    func testStringsDictVariableConsumesNumber() {
        XCTAssertTrue(PlaceholderFormatter.validate("%#@items@", args: [2]))
        XCTAssertFalse(PlaceholderFormatter.validate("%#@items@", args: ["2"]))
    }
}
